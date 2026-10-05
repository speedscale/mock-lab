# Tutorial app in Kubernetes

Manifests for the advanced (cluster) version of the tutorial: the orders service and its Postgres in the `tutorial` namespace, from published images.

## Deploy

Pick your language's overlay:

```sh
kubectl apply -k tutorial/k8s/overlays/go        # or java, python, node
kubectl -n tutorial rollout status deploy/tutorial-orders
```

Images are `ghcr.io/speedscale/mock-lab-tutorial-<language>:latest`, built for amd64 and arm64, so they run on kind and minikube on Apple silicon too.

Postgres keeps its data in an `emptyDir`: restarting its pod starts from empty tables.

## Send the tutorial traffic

From your laptop, through a port-forward:

```sh
kubectl -n tutorial port-forward svc/tutorial-orders 8080:8080
cd tutorial/go && go run ./cmd/traffic          # or your language's driver, see its README
```

Or from inside the cluster, as a Job (no local toolchain needed):

```sh
kubectl create -f tutorial/k8s/traffic/job.yaml
kubectl -n tutorial logs -f job/<name printed above> -c traffic
```

Either way the driver ends with `sent 135 requests, 0 unexpected`.

## Planted switches

The same switches as the local tutorial, set in place:

```sh
kubectl -n tutorial set env deployment/tutorial-orders APP_VERSION=v2   # regression
kubectl -n tutorial set env deployment/tutorial-orders APP_SLOW=1       # N+1 on GET /orders
kubectl -n tutorial set env deployment/tutorial-orders APP_VERSION- APP_SLOW-   # back to normal
```

## Remove it

```sh
kubectl delete namespace tutorial
```

`base/schema.sql` is a copy of `../contract/schema.sql`, because kustomize cannot read outside its directory; CI checks that they match.
