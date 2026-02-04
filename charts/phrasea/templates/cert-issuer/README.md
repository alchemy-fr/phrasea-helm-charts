# TLS Certificate Management with cert-manager and Let's Encrypt

Automatic TLS certificate management using cert-manager with Let's Encrypt DNS-01 challenges.

## Prerequisites

- **NGINX Ingress Controller** installed and configured with LoadBalancer service
- **cert-manager v1.13+** installed in the cluster
- **DNS webhook** installed for your provider (Scaleway, Gandi, or Route53)
- DNS properly configured to point to your LoadBalancer IP

## Supported DNS Providers

This chart supports automatic TLS certificate issuance via DNS-01 challenges with the following providers:

- **Scaleway DNS** - Requires webhook from `https://helm.scw.cloud/`
- **Gandi LiveDNS v5** - WIP  Requires webhook from `https://bwolf.github.io/cert-manager-webhook-gandi`
- **AWS Route53** - Native cert-manager support (no webhook required)

## Configuration

### Scaleway DNS

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true  # false for staging/testing
  rootHost: example.com
  provider: scaleway
  
  scaleway:
    accessKey: "SCWXXXXXXXXXXXXXXXXX"
    secretKey: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    # Or reference existing secret
    existingSecretName: scaleway-dns-credentials
    existingSecretAccessKeyKey: SCW_ACCESS_KEY
    existingSecretSecretKeyKey: SCW_SECRET_KEY
```

Required API permissions: `DNSFullAccess` or `DNSZonesRead` + `DNSRecordsWrite`

### Gandi LiveDNS v5

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true
  rootHost: example.com
  provider: gandi
  
  gandi:
    personalAccessToken: "your-gandi-pat-token"
    # Or reference existing secret
    existingSecretName: gandi-pat-secret
    existingSecretKey: api-token
```

Required permissions: "Manage domain name technical configurations"

### AWS Route53

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true
  rootHost: example.com
  provider: route53
  
  route53:
    region: eu-west-3
    accessKeyId: "AKIAXXXXX"
    secretAccessKey: "secret"
    hostedZoneId: "Z1234567890ABC"
```

Required IAM permissions: `route53:ChangeResourceRecordSets`, `route53:GetChange`, `route53:ListHostedZonesByName`

## How it works

1. **ClusterIssuer**: Created automatically for the selected DNS provider
2. **Certificate**: Generates wildcard certificate (`*.rootHost` + `rootHost`)
3. **Secret**: Stored as `<release-name>-ps-wildcard-tls`
4. **Ingress**: Automatically references the certificate via `ingress.tls.wildcard.externalSecretName`
5. **Renewal**: Automatic, 30 days before expiration (90-day validity)

## Verification

```bash
# Check ClusterIssuer status
kubectl get clusterissuer

# Check Certificate status
kubectl get certificate -n <namespace>

# Verify TLS secret exists
kubectl get secret <release-name>-ps-wildcard-tls -n <namespace>

# View certificate details
kubectl describe certificate <release-name>-ps-wildcard-certificate -n <namespace>
```
