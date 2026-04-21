# RUNBOOK — Azure Private Network Blueprint

This runbook documents real incidents encountered while building and validating the private networking infrastructure. Each entry follows the same format: symptom → investigation → root cause → fix → verification → lesson.

---

## Incident 1 — Storage account returned HTTP 400 from public internet despite `publicNetworkAccess = Disabled`

**Date:** April 20, 2026
**Severity:** High (suspected public data exposure)
**Status:** Resolved

### Symptom

During post-deployment validation, an HTTP request to the storage account's public FQDN from outside the VNet returned HTTP 400 instead of the expected HTTP 403.

The storage account had been deployed via Terraform with `public_network_access_enabled = false`. The expected behavior was that no public HTTP request should succeed or receive a meaningful application-layer response.

Observed:

    curl https://stzobiphase23951.blob.core.windows.net
    HTTP/1.1 400 Value for one of the query parameters specified in the request URI is invalid.
    Server: Microsoft-HTTPAPI/2.0

A 400 response from the storage HTTP listener indicated the request reached the service and was processed past the network layer. This raised the concern that `publicNetworkAccess = false` alone was not actually isolating the account from public traffic.

### Investigation

**Step 1 — Confirm Terraform setting was applied.**

Ran the Azure CLI to read live configuration:

    az storage account show \
      --name stzobiphase23951 \
      --resource-group rg-phase2-network \
      --query "{publicAccess:publicNetworkAccess, allowBlobPublic:allowBlobPublicAccess, networkRuleSet:networkRuleSet.defaultAction}" \
      --output table

Output:

    PublicAccess    AllowBlobPublic    NetworkRuleSet
    --------------  -----------------  ----------------
    Disabled        True               Allow

**Step 2 — Identified the gap.**

The `publicNetworkAccess` field was correctly `Disabled`. However, two other security settings were at their permissive defaults:

- `allowBlobPublicAccess = true` — anonymous blob access was still permitted at the container level
- `networkRuleSet.defaultAction = Allow` — the storage firewall's default action was to allow all traffic

These are three independent security layers on an Azure Storage Account. Setting only one is insufficient.

**Step 3 — Confirmed the 400 was a protocol-layer response, not authorization.**

Reran curl with a properly-formed query parameter (`?comp=list`) to test the actual auth path:

    curl https://stzobiphase23951.blob.core.windows.net/?comp=list

Now returned:

    HTTP/1.1 403 AuthorizationFailure

This confirmed: the 400 response to the initial malformed request had come from Azure's HTTP listener before the auth check ran. The actual authorization gate was partially enforcing, but inconsistent behavior across request types indicated weak defaults.

### Root cause

Azure Storage Account security is composed of three independent settings that must all be configured for public exposure to be fully blocked:

| Setting | Default | Secure value | Purpose |
|---------|---------|--------------|---------|
| `publicNetworkAccess` | Enabled | Disabled | Turns off the public endpoint entirely |
| `allowBlobPublicAccess` | true | false | Blocks anonymous blob/container reads |
| `networkRuleSet.defaultAction` | Allow | Deny | Default action for unmatched firewall rules |

The initial Terraform deployment set only the first. The other two remained at their permissive defaults, which explains why the storage endpoint still responded to public requests — even if individual operations were being denied, the surface area was not fully closed.

### Fix

Updated `azurerm_storage_account` resource in `main.tf` to explicitly set all three:

    resource "azurerm_storage_account" "main" {
      # ... other fields ...

      public_network_access_enabled   = false
      allow_nested_items_to_be_public = false

      network_rules {
        default_action = "Deny"
        bypass         = ["AzureServices"]
      }
    }

Ran `terraform plan -out=tfplan` followed by `terraform apply "tfplan"`. Single in-place update on the storage account, no resource recreation, no downtime.

### Verification

Re-ran the `az storage account show` command:

    PublicAccess    AllowBlobPublic    NetworkRuleSet
    --------------  -----------------  ----------------
    Disabled        False              Deny

All three settings now correctly configured.

Re-ran the external curl:

    curl https://stzobiphase23951.blob.core.windows.net/?comp=list
    HTTP/1.1 403 This request is not authorized to perform this operation.

Public access now consistently returns 403 AuthorizationFailure — the expected behavior.

Inside the prod spoke VNet (from the test VM), access via the Private Endpoint continues to work:

    curl https://stzobiphase23951.blob.core.windows.net
    Connected to (10.1.1.4) port 443

Private path functional, public path blocked.

### Lesson

A Private Endpoint isolates traffic to a private network path but does not by itself close the public path. And `publicNetworkAccess = false` on its own is not sufficient — Azure Storage has layered defaults that need to be set explicitly.

Three settings every production storage account needs:

1. `public_network_access_enabled = false`
2. `allow_nested_items_to_be_public = false`
3. `network_rules { default_action = "Deny" }`

Configuration default is not a security strategy. Each setting must be explicitly checked in code, and verified live after deployment.

---