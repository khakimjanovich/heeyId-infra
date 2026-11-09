# heeyid-infra

Runs heeyID on one Linux host with Docker Compose, the same way `ecom-infra` runs acquiring: Vault, Postgres, Valkey, Kafka, Keycloak (one realm per tenant), observability, the customer gateway, the admin gateway, the workers, the administrator panel and the public edge. This repo builds nothing; it pulls the images built from [heeyid](../heeyid).

Design: SAD MVP 1 §6 (deployment view), §7.2 (key custody), constraints C-1, C-4, C-10, C-15.

Rule: every input has no default. A missing value stops the install or the start with a clear error.
