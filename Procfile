controller: sh -c "FORCE_LOG_COLORS=1 ARGOCD_FAKE_IN_CLUSTER=true go run ./cmd/argocd-application-controller/main.go --loglevel debug --redis localhost:6379 --repo-server localhost:8081"
api-server: sh -c "FORCE_LOG_COLORS=1 ARGOCD_FAKE_IN_CLUSTER=true go run ./cmd/argocd-server/main.go --loglevel debug --redis localhost:6379 --disable-auth --insecure --repo-server localhost:8081 --staticassets ../argo-cd-ui/dist/app"
repo-server: sh -c "FORCE_LOG_COLORS=1 go run ./cmd/argocd-repo-server/main.go --loglevel debug --redis localhost:6379"
redis: docker run --rm --name argocd-redis -i -p 6379:6379 redis:5.0.3-alpine --save "" --appendonly no
