# The delivery pipeline

One `jenkins/Jenkinsfile` builds, tests and deploys all three integrations and
all three managed APIs.

---

## Contents

- [Design](#design)
- [Stages](#stages)
- [How "no silent partial deploy" is achieved](#how-no-silent-partial-deploy-is-achieved)
- [Environments](#environments)
- [Running it](#running-it)
- [Demonstrating that it fails cleanly](#demonstrating-that-it-fails-cleanly)

---

## Design

### One pipeline, not three

The APIs are declared once, at the top of the file:

```groovy
def APIS = ['account-balance', 'customer-profile', 'loan-eligibility']
```

Every later stage iterates that list, and the helper functions take the
environment as a parameter:

```groovy
def publishApim(String envName, List apis) { … }
def rollback(List steps, List apis)        { … }
def apimName(String api)                   { … }
```

Adding a fourth API means adding one list entry and one name mapping. There
are no per-API stage blocks to keep in sync, and dev and prod differ in which
params file is used rather than in logic.

### No Docker socket

MI is deployed by writing the built CAR into `deploy/carbonapps/`, which the
MI container watches through a bind mount. APIM is deployed over HTTPS with
`apictl`. Neither needs Docker, so the Jenkins container is not given the
host's Docker socket — mounting it would hand the pipeline root-equivalent
control of the host for no benefit.

### Credentials

The APIM admin username and password come from a Jenkins credential
(`apim-admin`) bound through `environment { APIM = credentials('apim-admin') }`
and used as `$APIM_USR` / `$APIM_PSW`. Nothing authenticating is committed.

---

## Stages

| Stage | Does | Touches the target? |
|---|---|---|
| Validate | XML well-formedness of every MI artifact; presence of each APIM project | No |
| Build MI | `mvn -B clean install` → `jamii-mi_1.0.0.car`, archived with fingerprint | No |
| Package APIM | Each apictl project packaged and archived | No |
| Test | Newman contract suite, 33 assertions, JUnit-reported | No |
| Snapshot current state | Current CAR, plus a live export of all three APIs | No |
| Dev: deploy MI | CAR into the watched directory, then poll the live API until it answers | **Yes** |
| Dev: publish APIM | Tier → three APIs → API Product, via apictl | **Yes** |
| Dev: smoke tests | The same suite again, against what was just deployed | No |
| Approve prod | Manual `input`, gated on `DEPLOY_PROD` | — |
| Prod: deploy and publish | Same functions, prod params | Gated |

Notes on three of them:

**Validate** runs `xmllint` over every `.xml` and `.dbs` artifact. A malformed
artifact fails the CAR deployment at runtime and takes the whole composite
application with it, so catching it here is much cheaper than catching it on
the target.

**Dev: deploy MI** does not assume the copy worked. It polls the live balance
API for up to 150 seconds and fails the stage if MI never answers, so a CAR
that deploys faulty is a pipeline failure rather than a silent one.

**Test and Dev: smoke tests** run the same collection twice — once before
deployment as a gate, once after as verification. The suite is nine requests
covering all three APIs: happy paths, the error envelope on 404 and 400, JSON
types (`amount` a number, `eligible` a boolean), correlation ID reuse, the
absence of upstream secrets in the customer projection, and the absence of XML
in the loans response.

Synapse unit tests are not wired; the `with-tests` Maven profile and plugin
configuration are present but unused. The contract suite is the project's test
suite.

---

## How "no silent partial deploy" is achieved

**1. Ordering.** Everything that can fail without side effects runs before
anything that can change the target. A broken artifact, a failed build or a
failing test ends the run with the environment untouched:

```
ROLLBACK: nothing was deployed, so nothing to undo. The target is untouched.
```

**2. MI ships as one CAR.** All three integrations live in a single composite
application, and MI reverts the whole composite if any artifact in it is bad.
The runtime is either fully on the new version or fully on the old one; it is
never half-updated.

**3. APIM imports are sequential and fail-fast**, in dependency order — the
throttling tier, then the three APIs, then the API Product that references
them. `sh` returns non-zero on the first failed import, which aborts the stage
before the remaining APIs are touched.

**4. A snapshot is taken immediately before deploying**, and `post { failure }`
restores from it. The snapshot exports what is *live*, not what git last had,
because those can differ.

**5. Rollback is armed before the imports begin**, not after they succeed:

```groovy
deployedSteps << 'apim:dev'   // marked BEFORE publishApim runs
publishApim('dev', APIS)
```

APIM is updated one API at a time, so a failure on the third leaves the first
two already changed. Marking success-only would skip the APIM rollback in
exactly the case that needs it.

**6. Only HTTP 409 is tolerated** when importing the tier and the product. An
already-existing policy is success; every other error fails the stage. apictl
reports an existing policy as `Status: 409` with no prose, so the check matches
the status code rather than wording. A blanket `|| true` there would be
precisely the silent partial deploy this design exists to prevent.

### Limit, stated honestly

This restores the previous version; it is not a distributed transaction.
Between the failing import and the rollback completing, a consumer could
briefly see a mix of versions. MI is atomic because it is one CAR; APIM is
sequential with a compensating restore, which is weaker. Closing the gap
properly needs per-environment pinned API revisions or blue/green gateways.

The pipeline logs that caveat on every rollback rather than implying it is
airtight:

```
ROLLBACK COMPLETE. Note: this restores the previous version, it is not a
distributed transaction. Between the failure and this point a consumer could
have seen mixed versions.
```

---

## Environments

`dev` is wired to the Docker Compose stack.

`prod` uses the same functions against the `prod` entries already present in
`apim/params/*-params.yaml`, gated behind the `DEPLOY_PROD` parameter and a
manual approval step. It is not connected to a real environment here; the
stage logs what it would do rather than pretending to deploy:

```
Stage "Approve prod" skipped due to when conditional
Stage "Prod: deploy and publish" skipped due to when conditional
```

Wiring it means a second Compose stack and a second apictl environment. No
pipeline logic changes.

---

## Running it

### 1. Start Jenkins

```bash
docker compose --profile ci build jenkins
docker compose --profile ci up -d jenkins
docker compose logs --tail 40 jenkins | grep -A2 'initial admin password'
```

Jenkins is on `http://localhost:8081` (8080 belongs to WireMock). Unlock it
with the password from the log and create an admin user. The required plugins
are baked into the image from `jenkins/plugins.txt`, so the setup wizard's
plugin step can be skipped.

Jenkins runs on `jamii-net`, so inside the pipeline the stack is reachable as
`http://mi:8290` and `https://apim:9443`, not `localhost`.

### 2. Add the APIM credential

**Manage Jenkins → Credentials → System → Global → Add Credentials**

- Kind: *Username with password*
- ID: `apim-admin` — the Jenkinsfile refers to this exact id
- Username / password: the APIM admin account (`admin` / `admin` locally)

### 3. Create the job

**New Item → Pipeline**, named `jamii-delivery`.

- Definition: *Pipeline script from SCM*
- SCM: *Git*
- Repository URL: the GitHub remote for this repository
- Branch: `*/main`
- Script Path: `jenkins/Jenkinsfile`

The pipeline builds **committed, pushed code**. Commit and push before
running, or the run will not include the latest edits — which is how CI
behaves anywhere else.

### 4. Run it

**Build with Parameters**, leaving `DEPLOY_PROD` unchecked and `BREAK_API` as
`none`.

Expected stages: Validate, Build MI, Package APIM, Test, Snapshot current
state, Dev: deploy MI, Dev: publish APIM, Dev: smoke tests. Prod stages are
skipped.

---

## Demonstrating that it fails cleanly

Worth running deliberately rather than hoping it never happens.

**Build with Parameters** again, setting `BREAK_API` to `loan-eligibility`.
The pipeline corrupts that API's tier reference before importing, reproducing
a `900305 The tier name is invalid` failure on the third of three imports.

Expected behaviour:

```
Validate / Build MI / Package APIM / Test   → all pass (33/33)
Snapshot current state                      → CAR + 3 API exports
Dev: deploy MI                              → MI is serving the new CAR
DELIBERATE FAILURE: corrupting the tier reference in loan-eligibility
  Tier already present (HTTP 409), continuing.
  account-balance   → Successfully imported API.
  customer-profile  → Successfully imported API.
  loan-eligibility  → Status: 400 {"code":900305,"message":"The tier name is invalid."}
Dev: smoke tests / Approve prod / Prod       → skipped
ROLLBACK: undoing [mi:dev, apim:dev]
ROLLBACK: restored the previously deployed MI composite application
ROLLBACK: restored account-balance
ROLLBACK: restored customer-profile
ROLLBACK: restored loan-eligibility
Finished: FAILURE
```

Two APIs had already been imported when the third failed, and all three are
restored rather than guessing which succeeded. The rollback also runs
`git checkout -- apim/apis` so the re-import uses the committed definitions,
not the corrupted working copy.

Then confirm the previous versions still answer:

```bash
curl -sS http://localhost:8290/accounts/1000000001/balance
curl -sS http://localhost:8290/customers/1
apictl get apis -e dev -k --format '{{.LifeCycleStatus}}' | grep -c PUBLISHED   # 3
```
