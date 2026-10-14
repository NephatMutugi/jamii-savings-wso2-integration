# Jamii Savings — WSO2 Integration Layer

Three banking APIs on WSO2 Micro Integrator, governed through WSO2 API
Manager, delivered by one Jenkins pipeline. Each fronts a different kind of
backend; all three present the same contract to callers regardless of what
sits behind them.

| API | Gateway path | Backend | Security | Tier |
|---|---|---|---|---|
| Account Balance | `GET /jamii/accounts/v1/{accountNumber}/balance` | MySQL, via an MI data service | OAuth2 | `Gold` |
| Customer Profile | `GET /jamii/customers/v1/{customerId}` | REST (DummyJSON) | OAuth2 | `Gold` |
| Loan Eligibility | `POST /jamii/loans/v1/eligibility` | SOAP (dneonline Calculator) | API Key | `SoapBackendGuard` |

Detail lives in [docs/integrations.md](docs/integrations.md) (the three
integrations, logging, masking, the error contract),
[docs/apim.md](docs/apim.md) (security, tiers, the custom policy, the API
Product), [docs/pipeline.md](docs/pipeline.md) (pipeline design and the
rollback demo) and [docs/devportal.md](docs/devportal.md) (how a consumer
subscribes).

## Architecture decisions and trade-offs

MI owns protocol translation, validation, error mapping and masking; APIM owns
identity, throttling and the published contract. Three APIs over three backend
technologies share one inbound sequence, one fault classifier and one error
serialiser, so the error envelope is identical by construction rather than by
discipline — there is exactly one place where an error body is built.

- **Validation at the edge as well as a bound parameter** — the account number
  is checked against `^[0-9]{10}$` before the SQL `?` binding, so injection is
  a 400 that never reaches the driver. Cost: a format assumption hard-coded in
  mediation.
- **Masking in two layers** — in mediation before logging, and again via
  log4j2's `%mm` at write time. The second looks redundant until you consider
  MI's own loggers, which the integration does not control and which are the
  lines most likely to carry a raw value.
- **Projection, not pass-through** — the customer API lists output fields
  explicitly, so `password`, `ssn` and `bank` cannot leak and adding a field
  is deliberate. Cost: upstream additions need a code change.
- **A tighter tier on one API** — Loan Eligibility gets 10 req/min while the
  others stay on `Gold`, because it is the only API fronting a shared
  third-party service Jamii neither controls nor pays for. The limit protects
  the dependency, not Jamii's capacity.
- **Rollback is a compensating restore, not a transaction** — MI is atomic
  because all three integrations ship as one CAR, but APIM is imported one API
  at a time with a snapshot restore afterwards, so a consumer could briefly
  see mixed versions. The pipeline logs that caveat on every rollback.
- **Endpoint suspension disabled** — correct in production, but it makes one
  failure break every later call, which hides the individual failure paths.
- **Gateway errors keep APIM's format** — consumers see two error shapes.
  Aligning them means overriding APIM's auth and throttle handlers, changing
  behaviour for every API on that gateway.
- **The customer backend URL is literal** — MI's `${configs.X}` resolver reads
  a startup-flag config file, not the environment, so externalising it means
  overriding the stock image's entrypoint. Switching backends is a rebuild.

## Assumptions

A 10-digit account number is Jamii's format. Eligibility is a 40%
debt-to-income threshold, standing in for real credit policy. KES is the only
seeded currency, though both the column and the envelope carry it. Correlation
IDs are not secrets and are logged in full; anything identifying a person is
not. One APIM tenant with the stock admin user — role-based visibility and
multi-tenancy are out of scope. Certificates are self-signed locally, hence
`-k`. The public backends are assumed available; WireMock stubs cover the
failure paths so demonstrations do not depend on third parties misbehaving.

## With more time

Align gateway error responses with the integration envelope. Wire a real prod
environment — the params, functions and approval gate already exist; only the
target is missing. Add Synapse unit tests for mediation logic, so a
transformation regression is caught without a running stack. Add metrics and
correlation-ID-keyed tracing across gateway → MI → backend. Re-enable
suspension with circuit breaking, plus a short-TTL cache on the customer
proxy. Read the datasource password from a vault rather than the environment.
Then the two bonus items: an aggregation endpoint over all three, and
eligibility events published to a broker with a dead-letter queue.

## How to run it locally

Needs Docker Compose, JDK 11+, Maven 3.8+; Newman for the tests and
[apictl 4.6.0](https://github.com/wso2/product-apim-tooling/releases) to
publish by hand (the pipeline has both).

```bash
# 1. Configure, changing every value. JAMII_DB_URL must have no query
#    parameters: MI writes it into master-datasources.xml unescaped, so an
#    "&" invalidates that file and every datasource disappears.
cp .env.example .env

# 2. JDBC driver (gitignored; fetch once)
curl -sSL -o mi/deployment/libs/mysql-connector-j.jar \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/9.1.0/mysql-connector-j-9.1.0.jar

# 3. Start the stack; wait for db, mi and apim to report healthy (APIM takes
#    a couple of minutes cold). schema.sql and seed.sql apply automatically.
docker compose up -d && docker compose ps

# 4. Build and deploy the integrations
(cd mi && mvn -B clean install)
cp mi/target/jamii-mi_1.0.0.car deploy/carbonapps/

# 5. Verify
curl -s http://localhost:8290/accounts/1000000001/balance | jq
curl -s http://localhost:8290/customers/1 | jq
curl -s -X POST http://localhost:8290/loans/eligibility \
  -H 'Content-Type: application/json' \
  -d '{"customerId":1,"monthlyIncome":150000,"monthlyDebt":20000,"requestedAmount":600000,"termMonths":24}' | jq

# 6. Or run the contract suite (9 requests, 33 assertions)
newman run tests/postman/jamii-mi.postman_collection.json \
  -e tests/postman/dev.postman_environment.json
```

Publishing to APIM is in [docs/apim.md](docs/apim.md); the pipeline
(`docker compose --profile ci up -d jenkins`) is in
[docs/pipeline.md](docs/pipeline.md).
