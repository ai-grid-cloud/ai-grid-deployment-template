# Join each site to the grid

Labels on the site's ManagedCluster make it a grid site in its role. The hub then installs OpenShift AI, MaaS (on
ingress and combined sites), the grid, and the tenant settings. Use the shell variables from
[prepare each site](05-prepare-site.md).

## 1. Add the site's values

For an ingress or combined site, add `values/clusters/SITE/rhoai.yaml` to your deployment repository and push it
**before** you label the site. Without it, the site's `rhoai-SITE` Application doesn't render. Inference sites need no
file.

1. Choose the MaaS hostname prefix. Tenants call `https://PREFIX.apps.CLUSTER_DOMAIN`:

   ```yaml
   # values/clusters/SITE/rhoai.yaml
   components:
     aigateway:
       modelsAsAService:
         gateway:
           annotations:
             ai-grid/maas-gateway-hostname-prefix: PREFIX
   ```

2. Give the MaaS gateway a certificate tenants trust. The gateway otherwise presents its in-cluster service
   certificate on the public hostname, and a router Route can't help, because OpenShift points the hostname straight
   at the gateway's own load balancer. For the same reason an HTTP-01 issuer can't solve; you need a DNS-01
   ClusterIssuer on the site ([before you start](01-before-you-start.md#3-accounts-and-credentials)). The library
   has no input for this certificate yet ([known gaps](appendix-c-gaps.md)), so you add it as your own app
   ([MaaS gateway certificate](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/spokes/maas-certificate.md)).

   1. Add the Certificate to your deployment repository, as `sites/SITE/maas-tls/certificate.yaml`:

      ```yaml
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: maas-gateway-public
        namespace: openshift-ingress
      spec:
        secretName: maas-gateway-public-tls
        dnsNames:
          - PREFIX.apps.CLUSTER_DOMAIN
        issuerRef:
          kind: ClusterIssuer
          name: DNS01_ISSUER
      ```

   2. Add an Application that delivers it to the site, as `apps/SITE-maas-tls.yaml`. Your root's own-apps generator
      picks it up. The hub's Argo CD reaches each site through ACM's cluster proxy, at
      `https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/SITE`:

      ```yaml
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: SITE-maas-tls
        namespace: openshift-gitops
      spec:
        project: default
        source:
          repoURL: '@deploymentRepoURL@'
          targetRevision: '@deploymentRevision@'
          path: sites/SITE/maas-tls
        destination:
          server: https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/SITE
          namespace: openshift-ingress
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
      ```

   3. Point the gateway's HTTPS listener at the Certificate's Secret, in the same `values/clusters/SITE/rhoai.yaml`.
      Helm replaces lists whole, so give both of the chart's listeners:

      ```yaml
      components:
        aigateway:
          modelsAsAService:
            gateway:
              annotations:
                ai-grid/maas-gateway-hostname-prefix: PREFIX
              spec:
                listeners:
                  - name: http
                    port: 80
                    protocol: HTTP
                    allowedRoutes:
                      namespaces:
                        from: Selector
                        selector:
                          matchExpressions:
                            - key: kubernetes.io/metadata.name
                              operator: In
                              values: [openshift-ingress, models-as-a-service, redhat-ai-gateway-infra]
                  - name: https
                    port: 443
                    protocol: HTTPS
                    allowedRoutes:
                      namespaces:
                        from: Selector
                        selector:
                          matchExpressions:
                            - key: kubernetes.io/metadata.name
                              operator: In
                              values: [openshift-ingress, models-as-a-service, redhat-ai-gateway-infra]
                    tls:
                      mode: Terminate
                      certificateRefs:
                        - group: ""
                          kind: Secret
                          name: maas-gateway-public-tls
      ```

   Replace the following:

   - `SITE`: the site's ACM cluster name.
   - `PREFIX`: the MaaS hostname prefix from the previous step. With the library's Keycloak, use `maas`
     ([Keycloak](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/04-tenant-identity.md#keycloak)).
   - `CLUSTER_DOMAIN`: the site's cluster domain, so the name matches `oc get ingresses.config.openshift.io cluster
     -o jsonpath='{.spec.domain}'` with `PREFIX.` in front of it.
   - `DNS01_ISSUER`: your DNS-01 ClusterIssuer on the site.

   If you bring your own certificate instead, create Secret `openshift-ingress/maas-gateway-public-tls`
   (`kubernetes.io/tls`) on the site and skip the Certificate and its Application.

   Check, after the site is labelled: `oc --context "$SITE_CONTEXT" get certificate maas-gateway-public -n
   openshift-ingress` shows `READY` `True`.

3. Commit and push.

## 2. Label the site

```sh
oc --context "$HUB_CONTEXT" label managedcluster "$SITE" ai-grid/enabled=true ai-grid/role=ROLE location=LOCATION
```

Replace the following:

- `ROLE`: `ingress`, `inference` or `combined`.
- `LOCATION`: a label for where the site is, such as `us-east`. The console shows it.

You should see `managedcluster.cluster.open-cluster-management.io/SITE labeled`. Within a minute the hub creates the
site's Applications:

```sh
oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops | grep -- "-$SITE"
```

You should see at least `rhoai-SITE-…`, `cluster-config-SITE-…` and `acm-submariner-SITE`, plus `maas-db-SITE` on an
ingress or combined site. OpenShift AI takes 45 to 60 minutes.

## 3. Verify

1. OpenShift AI is ready:

   ```sh
   oc --context "$SITE_CONTEXT" get datasciencecluster -o jsonpath='{.items[0].status.phase}{"\n"}'
   ```

   You should see `Ready`.

   On RHOAI 3.6 nightlies built after 2026-11-06, `KserveReady` can flap to `False` with
   `modelcache: cleanup ... kserve-leader-election-role`, and the phase with it. Models keep serving. Check again, or
   watch for a minute (`oc get datasciencecluster -w`); a site that returns to `Ready` is fine
   ([troubleshooting](10-troubleshooting.md#kserveready-flaps-false-on-a-site)).

2. The site is in the grid:

   ```sh
   oc --context "$SITE_CONTEXT" get gridnetworks,gridsites -A
   ```

   You should see the GridNetwork, and the site's GridSite `Available`.

3. The hub's Policies for the site are Compliant:

   ```sh
   oc --context "$HUB_CONTEXT" get policies -n "$SITE"
   ```

   You should see every Policy `Compliant`.

4. The hub's Applications are all Healthy now, including Submariner, `limitador-redis` and the MaaS database
   ServiceExport, which waited for the first site:

   ```sh
   oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops \
     -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
     | grep -v ' Synced Healthy$'
   ```

   You should see no output.

5. On an ingress or combined site, the MaaS hostname answers with a trusted certificate:

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' "https://PREFIX.apps.CLUSTER_DOMAIN/v1/models"
   ```

   You should see `401` (no token yet) and no certificate error.

## Checkpoint

- Every site's DataScienceCluster is `Ready` and its GridSite `Available`.
- Every hub Policy for the site is `Compliant`, and every hub Application is `Synced` and `Healthy`.
- Each ingress or combined site's MaaS hostname answers `401` over trusted TLS.
