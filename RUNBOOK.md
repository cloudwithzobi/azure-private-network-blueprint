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

## Incident 2 — Storage hostname resolving to public IP from prod VNet despite Private Endpoint being Approved

**Date:** April 20, 2026
**Severity:** High (private traffic silently leaving the VNet)
**Status:** Resolved

### Symptom

An engineer reported that the application in the prod spoke had stopped being able to reach the storage account. No recent code changes. No Terraform changes committed.

From a VM inside `vnet-spoke-prod`, DNS resolution for the storage account FQDN was returning a public IP instead of the expected private IP of the Private Endpoint:

    nslookup stzobiphase23951.blob.core.windows.net
    Non-authoritative answer:
    stzobiphase23951.blob.core.windows.net  canonical name = stzobiphase23951.privatelink.blob.core.windows.net.
    Name:   stzobiphase23951.privatelink.blob.core.windows.net
    Address: 20.60.42.235

Expected: `10.1.1.4` (the private IP of the Private Endpoint NIC in the prod spoke workload subnet).

The `privatelink.*` CNAME chain was still present, which suggested the public endpoint response was coming through a DNS fallthrough — the VNet was no longer finding the private zone.

### Investigation

Investigation methodology: verify the symptom, then isolate which layer failed — the Private Endpoint itself, the DNS record inside the zone, or the link between the zone and the VNet.

**Step 1 — Verify the Private Endpoint is healthy.**

    az network private-endpoint show \
      --resource-group rg-phase2-network \
      --name pe-storage-blob \
      --query "{State:provisioningState, ConnectionState:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" \
      --output table

Result: `State: Succeeded`, `ConnectionState: Approved`. Private Endpoint is not the problem.

**Step 2 — Verify the DNS A record in the zone still exists.**

    az network private-dns record-set a show \
      --resource-group rg-phase2-network \
      --zone-name privatelink.blob.core.windows.net \
      --name stzobiphase23951 \
      --query "aRecords[].ipv4Address" \
      --output tsv

Result: `10.1.1.4`. Record intact, auto-registered by the PE, pointing to the correct private IP.

**Step 3 — Check if the DNS zone is linked to the prod VNet.**

    az network private-dns link vnet list \
      --resource-group rg-phase2-network \
      --zone-name privatelink.blob.core.windows.net \
      --output table

Result: empty response. No VNet links exist on the blob DNS zone.

### Root cause

The VNet link `link-blob-to-prod`, which connects `privatelink.blob.core.windows.net` to `vnet-spoke-prod`, had been deleted outside of Terraform (via Azure CLI). This is a form of **configuration drift** — a change made to the live infrastructure without going through the IaC workflow, causing reality to diverge from the Terraform state file.

With no VNet link, the prod VNet had no way to find the private DNS zone. DNS queries for the blob hostname fell through to public DNS and returned the storage account's public IP. The Private Endpoint, the DNS record, and the zone itself were all intact — but the connection between the zone and the VNet was missing.

This is the most common real-world Private Endpoint misconfiguration. It fails silently: the portal shows all resources as "Succeeded" and "Approved," but traffic never actually uses the private path.

### Fix

Two options were considered:

1. **Direct CLI recreation** — run `az network private-dns link vnet create ...` to manually restore the link.
2. **Terraform drift reconciliation** — run `terraform plan` / `terraform apply` to let Terraform detect the drift and restore the link from state.

Option 2 was chosen because IaC should be the single source of truth. CLI fixes create undocumented drift that future engineers cannot reason about.

    terraform plan -out=tfplan
    # Plan: 1 to add, 0 to change, 0 to destroy.
    terraform apply "tfplan"
    # Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Terraform recognized the missing link, proposed to add it, and restored it from the existing code definition.

### Verification

Re-ran DNS resolution from the VM in the prod spoke:

    nslookup stzobiphase23951.blob.core.windows.net
    Non-authoritative answer:
    stzobiphase23951.blob.core.windows.net  canonical name = stzobiphase23951.privatelink.blob.core.windows.net.
    Name:   stzobiphase23951.privatelink.blob.core.windows.net
    Address: 10.1.1.4

Private IP restored. Private path functional.

Re-ran zone link query:

    az network private-dns link vnet list \
      --resource-group rg-phase2-network \
      --zone-name privatelink.blob.core.windows.net \
      --output table

Result: `link-blob-to-prod` present, state `Completed / Succeeded`.

### Lesson

Three lessons from this incident:

1. **Private Endpoints, DNS records, and VNet links are three separate resources.** The PE can be healthy, the record can be correct, but if the zone isn't linked to the VNet, DNS fails through to public. Investigating Private Endpoint issues means checking all three layers, not assuming one is sufficient.

2. **Investigation methodology matters.** Starting with `nslookup` loops would have wasted time on symptoms. Going straight to the Azure CLI to check the config of each resource in the chain isolated the failure in three commands.

3. **Configuration drift is a real production risk.** Any change made outside of Terraform creates divergence between state and reality. The correct reconciliation path is to use Terraform to bring reality back into alignment with code, not to update code to match a manual change. CLI fixes in emergencies are acceptable; leaving them undocumented is not.

---