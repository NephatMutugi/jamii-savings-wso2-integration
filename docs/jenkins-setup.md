# Running the pipeline

The pipeline builds the MI composite application, packages the APIM projects,
runs the contract tests, deploys to MI and imports all three APIs plus the
throttling tier and the API Product into APIM.

## Why no Docker socket

MI is deployed by writing the built CAR into `deploy/carbonapps/`, which the
MI container watches through a bind mount, and APIM is deployed over HTTPS
with `apictl`. Neither needs Docker, so the Jenkins container is not given the
host's Docker socket. Mounting it would hand the pipeline root-equivalent
control of the host for no benefit.

## 1. Start Jenkins

```bash
docker compose --profile ci build jenkins
docker compose --profile ci up -d jenkins
docker compose logs --tail 40 jenkins | grep -A2 'initial admin password'
```

Jenkins is on `http://localhost:8081` (8080 belongs to WireMock). Unlock it
with the password from the log, install the suggested plugins, and create an
admin user.

It runs on `jamii-net`, so inside the pipeline the stack is reachable as
`http://mi:8290` and `https://apim:9443`, not `localhost`.

## 2. Add the APIM credential

**Manage Jenkins → Credentials → System → Global → Add Credentials**

- Kind: *Username with password*
- ID: `apim-admin` (the Jenkinsfile refers to this exact id)
- Username: `admin`, Password: `admin` for the local stack

## 3. Create the job

**New Item → Pipeline**, named `jamii-delivery`.

- Definition: *Pipeline script from SCM*
- SCM: *Git*, Repository URL: `/workspace`
- Branch: `*/main`
- Script Path: `jenkins/Jenkinsfile`

The repo is bind-mounted at `/workspace`, so Jenkins clones the local git
repository. That means **the pipeline builds committed code**: commit before
running, or the run will not include your latest edits. That is deliberate,
and it is how CI behaves anywhere else.

## 4. Run it

Build with Parameters, leaving `DEPLOY_PROD` unchecked and `BREAK_API` as
`none`.

Expected stages: Validate, Build MI, Package APIM, Test, Snapshot current
state, Dev: deploy MI, Dev: publish APIM, Dev: smoke tests.

## 5. Demonstrate that it fails cleanly

This is the part the brief calls out by name, so it is worth running
deliberately rather than hoping it never happens.

Build with Parameters again, setting `BREAK_API` to `loan-eligibility`. The
pipeline corrupts that API's tier reference before importing, reproducing the
same `900305 The tier name is invalid` failure seen when the tier genuinely
did not exist.

Expected behaviour:

1. Validate, build, package and test all pass, because the corruption is
   introduced at the deployment stage.
2. MI deploys successfully.
3. The APIM publish stage fails on the corrupted API.
4. `post { failure }` runs the rollback, which restores the snapshotted CAR
   and re-imports the APIs captured before deployment.
5. The build is marked FAILURE, and the log names exactly what was rolled
   back.

Afterwards, confirm the previous versions still answer:

```bash
curl -sS http://localhost:8290/accounts/1000000001/balance
curl -sS http://localhost:8290/customers/1
```

## How "no partial deploy" is achieved

1. **Everything that can fail without side effects runs first.** A broken
   spec, a failed build or a failing test stops the run with the target
   untouched.
2. **MI ships as one CAR.** All three integrations are in a single composite
   application and MI reverts the whole thing if any artifact is bad, so the
   runtime is never half-updated. This was discovered rather than designed: a
   single malformed endpoint took an unrelated working API offline during
   development.
3. **APIM imports are sequential and fail fast**, in dependency order: the
   throttling tier, then the three APIs, then the API Product.
4. **Both sides roll back** from a snapshot taken immediately before
   deployment.

**Limit, stated honestly:** this restores the previous version; it is not a
distributed transaction. Between the failing import and the rollback
completing, a consumer could briefly see mixed versions. Narrowing that window
would need blue/green gateways or APIM revision pinning.

## Environments

`dev` is wired. `prod` uses the same functions against the `prod` entries
already present in `apim/params/*-params.yaml`, gated behind the
`DEPLOY_PROD` parameter and a manual approval step. It is not connected to a
real environment in this submission; the stage logs what it would do.
