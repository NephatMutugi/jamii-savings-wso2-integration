# The three integrations

Detail behind the summary in the [README](../README.md). Each API fronts a
different kind of backend and all three present the same contract to callers.

Direct MI endpoints are shown here (`localhost:8290`), because that is where
the integration behaviour lives. The managed, authenticated surface is the
APIM gateway on `localhost:8243` — see [apim.md](apim.md).

---

## Contents

- [1. Account Balance — database-backed](#1-account-balance--database-backed)
- [2. Customer Profile — REST proxy](#2-customer-profile--rest-proxy)
- [3. Loan Eligibility — SOAP to REST](#3-loan-eligibility--soap-to-rest)
- [Correlation IDs](#correlation-ids)
- [Logging](#logging)
- [Masking](#masking)
- [Malformed input is 400, never 500](#malformed-input-is-400-never-500)
- [The error contract](#the-error-contract)

---

## 1. Account Balance — database-backed

`GET /accounts/{accountNumber}/balance`

`AccountsAPI` → `AccountsDSEP` → `AccountsDS.dbs` → MySQL.

```bash
curl -s http://localhost:8290/accounts/1000000001/balance | jq
```

```json
{
  "accountNumber": "1000000001",
  "status": "ACTIVE",
  "balance": { "amount": 125430.50, "currency": "KES" },
  "requestId": "9f1c2e4a-55d7-4f0a-9bb1-6a2b7c3d8e11",
  "timestamp": "2026-10-13T09:41:22.108+00:00"
}
```

`balance.amount` is a JSON number, not a string. `status` is one of `ACTIVE`,
`DORMANT`, `CLOSED`, read from the row rather than inferred.

### The query

The row is read by a **data service**
(`mi/src/main/wso2mi/artifacts/data-services/AccountsDS.dbs`), not by
hand-built SQL in the mediation flow:

```sql
SELECT account_number, status, balance_amount, currency FROM accounts WHERE account_number = ?
```

The account number is bound as an `IN` parameter by the driver. Nothing is
concatenated into the statement at any point.

Independently of that, the format is validated at the edge — `^[0-9]{10}$` —
so a value shaped like SQL is rejected with 400 before a database call is even
attempted:

```bash
curl -i "http://localhost:8290/accounts/1'%20OR%20'1'='1/balance"   # 400 INVALID_REQUEST
```

### Three distinct outcomes

```bash
curl -i http://localhost:8290/accounts/9999999999/balance            # 404 ACCOUNT_NOT_FOUND
docker compose stop db
curl -i http://localhost:8290/accounts/1000000001/balance            # 503 DATA_SOURCE_UNAVAILABLE
docker compose start db
```

These are genuinely different code paths, and neither is a 500:

| Outcome | Detected by |
|---|---|
| No such account | The data service returns `<accounts/>` with no child row |
| Database unreachable | A `DataServiceFault` element in the data service response |

`$axis2:HTTP_SC` is deliberately **not** used to detect the failure here — it
does not reliably carry the data service's status in this flow.

### Datasource

`JamiiDS` is declared in `mi/deployment/deployment.toml` and takes its URL,
user and password from environment variables, so no credential is committed.
The data service is internal: it is called over localhost by `AccountsAPI` and
is never published through APIM. The managed API surface is `AccountsAPI`.

---

## 2. Customer Profile — REST proxy

`GET /customers/{customerId}`

`CustomersAPI` → `CustomerBackendEP` → `https://dummyjson.com/users/{id}`.

```bash
curl -s http://localhost:8290/customers/1 | jq
```

```json
{
  "customerId": 1,
  "firstName": "Emily",
  "lastName": "Johnson",
  "email": "emily.johnson@x.dummyjson.com",
  "phone": "+81 965-431-3024",
  "city": "Phoenix",
  "requestId": "…",
  "timestamp": "…"
}
```

### Backend choice

DummyJSON, chosen over the better-known alternatives (JSONPlaceholder, ReqRes)
for three specific reasons:

1. Its user records carry realistic sensitive fields — `password`, `ssn`,
   `bank.cardNumber`, `crypto.wallet`, `email`, `phone`. That makes the
   difference between a projection and a pass-through demonstrable rather
   than theoretical.
2. It returns a proper `404` for unknown ids, so the not-found path is the
   backend's real behaviour rather than something simulated.
3. No authentication, no signup, and no rate limit that interferes with a
   demonstration.

### Projection, not pass-through

Compare what upstream returns with what crosses the boundary:

```bash
curl -s https://dummyjson.com/users/1 | jq 'keys'
curl -s http://localhost:8290/customers/1 | jq 'keys'
```

The upstream record carries `password`, `ssn`, `bank` and `crypto`. None of
them appear in the response. The transformation is an explicit field list in a
`payloadFactory`, so adding a field to the API is a deliberate act rather than
something that happens when upstream adds one.

### Header manipulation, both directions

**Outbound** — stripped before the request leaves MI:

| Header | Why |
|---|---|
| `Authorization` | Gateway credentials are for the gateway, not a third party |
| `X-JWT-Assertion` | APIM's internal assertion; leaks claims about the caller |
| `Cookie` | Caller session state has no meaning upstream |
| `X-Internal-Debug` | Internal-only toggle |
| `Accept-Encoding` | Forwarding `gzip, deflate, br` makes the backend return a compressed body that the passthrough transport cannot parse (`601000`) |

**Inbound** — every upstream header is discarded (`TRANSPORT_HEADERS`
removed), then only `X-Correlation-ID` and the content type are re-added. No
`Server`, `X-Powered-By`, `Set-Cookie`, CORS or upstream rate-limit header
reaches a client.

### Timeout, distinct from unavailability

```xml
<timeout><duration>3000</duration><responseAction>fault</responseAction></timeout>
```

| Condition | Result |
|---|---|
| Backend slow | `504 BACKEND_TIMEOUT`, in under four seconds |
| Backend unreachable | `503 BACKEND_UNAVAILABLE` |
| Unknown customer | `404 CUSTOMER_NOT_FOUND` |
| Anything else | `502 BACKEND_ERROR` |

To demonstrate the timeout, point `CustomerBackendEP` at the WireMock stub
(`http://wiremock:8080/users/{uri.var.customerId}`, a 5-second delay) and
rebuild. For unavailability, point it at a closed port.

---

## 3. Loan Eligibility — SOAP to REST

`POST /loans/eligibility`

`LoansAPI` → `CalculatorSoapEP` → `http://www.dneonline.com/calculator.asmx`.

```bash
curl -s -X POST http://localhost:8290/loans/eligibility \
  -H 'Content-Type: application/json' \
  -d '{"customerId":1,"monthlyIncome":150000,"monthlyDebt":20000,"requestedAmount":600000,"termMonths":24}' | jq
```

```json
{
  "eligible": true,
  "monthlyInstalment": 25000,
  "debtToIncomeRatio": 0.3,
  "reason": "WITHIN_DTI_LIMIT",
  "requestId": "…",
  "timestamp": "…"
}
```

`eligible` is a JSON boolean. No SOAP envelope, namespace or XML fragment
appears in the response — not on success, and not on failure.

### Service choice and mapping

The dneonline Calculator is a long-lived public SOAP 1.1 service with a
published WSDL, no auth, and — importantly — deterministic arithmetic, so a
test asserting an exact number stays valid.

There is no public SOAP *credit-scoring* service to call. What matters is that
the integration genuinely performs SOAP-to-REST translation, so the Calculator
stands in for the scoring service and its `Divide` operation carries the one
piece of arithmetic the decision needs:

| Loan concept | SOAP call | Result |
|---|---|---|
| `requestedAmount` | `intA` | |
| `termMonths` | `intB` | |
| monthly instalment | `Divide(intA, intB)` → `DivideResult` | `monthlyInstalment` |

MI then applies the lending rule locally:

```
debtToIncomeRatio = (monthlyInstalment + monthlyDebt) / monthlyIncome
eligible          = debtToIncomeRatio <= 0.40
```

The remote service computes, the integration decides, and the caller gets a
banking answer (`eligible`, `reason`) rather than an arithmetic one. Swapping
in a real scoring service means changing one endpoint and one payload
transformation; the API contract does not move.

### Three implementation details

- The endpoint is declared `format="soap11"`, so the mediation builds only the
  `<tem:Divide>` operation element and MI wraps the envelope. Building a full
  envelope *and* setting the format nests one inside the other.
- `requestedAmount` and `termMonths` are coerced to integers with XPath 1.0
  string functions before the call, because `intA`/`intB` are integer-typed
  and `round()` alone can render as `600000.0`.
- Fault detection precedes result parsing. A Fault envelope has no
  `DivideResult`, so parsing first would misreport a fault as a malformed
  response.

### SOAP Faults

A SOAP Fault becomes `422 ELIGIBILITY_CHECK_REJECTED`. The `faultcode` and
`faultstring` are logged at WARN and never returned; the response body
contains no `<` character at all.

Validation rejects zero or negative `monthlyIncome`, `requestedAmount` and
`termMonths` with 400 before the call — which is also what stops the service
ever being asked to divide by zero. To exercise the fault path deliberately,
point `CalculatorSoapEP` at `http://wiremock:8080/calculator.asmx`
(`tests/wiremock/mappings/soap-fault.json`) and rebuild.

---

## Correlation IDs

One identifier ties the gateway, the integration and the backend call
together. It is also the `requestId` in every response body and the
`X-Correlation-ID` response header.

```bash
curl -s -H 'X-Correlation-ID: demo-req-001' http://localhost:8290/customers/1 | jq -r .requestId
# demo-req-001
```

A caller-supplied value is reused only if it matches `^[A-Za-z0-9-]{8,64}$`;
anything else is replaced with a generated UUID. That is deliberate — an
unvalidated client header ends up in log files, and log files get read by
tools that interpret what they find.

The same check exists at the gateway in the `correlationIdInjector` policy, so
the ID is present even for traffic that never reaches MI.

---

## Logging

Each API emits three structured events sharing one `requestId`:

```
event = REQUEST_IN,   requestId = …, api = CustomersAPI, method = GET
event = BACKEND_CALL, requestId = …, backend = CustomerBackend, customerId = 1
event = RESPONSE_OUT, requestId = …, status = 200, customerId = 1
```

Error paths add a `FAULT` event at ERROR carrying the Synapse error code and
message, and the loans API adds a `SOAP_FAULT` event at WARN. Both are logged
and never returned, so backend hostnames, SQL and stack traces cannot reach a
client.

```bash
docker compose logs mi | grep "requestId = demo-req-001"
```

---

## Masking

Two independent layers.

**1. In mediation.** The sensitive value is masked *before* it is ever passed
to a log mediator:

```xml
<property name="maskedAccount"
          expression="fn:concat('******', fn:substring($ctx:accountNumber, fn:string-length($ctx:accountNumber) - 3))"/>
```

The account number is logged as `******0001`. Customer name, email and phone
are simply never logged. The request path is not logged either, because it
carries the identifier.

**2. In log4j2.** `mi/deployment/deployment.toml` renders masking patterns for
`ACCOUNT_NUMBER`, `EMAIL` and `PHONE` into `conf/wso2-log-masking.properties`,
and `mi/deployment/log4j2.properties` uses the `%mm` masking converter on
every message-carrying appender.

The second layer exists because the first only covers the log lines this
repository writes. MI's own loggers — a stack trace on a failure path, a
transport-level warning — are not under the integration's control, and those
are exactly the lines likely to carry a raw value. Mediation-level masking
alone leaves that gap; `%mm` closes it.

The `PHONE` pattern requires a leading `+` so that ordinary digit sequences in
logs (ports, counts, timestamps) are not masked into unreadability.

---

## Malformed input is 400, never 500

| Request | Result |
|---|---|
| `GET /accounts/abc/balance` | 400 `INVALID_REQUEST` |
| `GET /customers/abc` | 400 `INVALID_REQUEST` |
| `POST /loans/eligibility` with `{"bad":` | 400 `INVALID_REQUEST` |
| `POST /loans/eligibility` missing `termMonths` | 400 `INVALID_REQUEST` |
| `POST /loans/eligibility` with `monthlyIncome: 0` | 400 `INVALID_REQUEST` |
| `GET /accounts/1000000001/nonsense` | 404 `RESOURCE_NOT_FOUND` |

Path and body parameters are validated against explicit patterns in each API
before any backend call. A body that is not JSON at all fails earlier, during
message building, and `Common_Fault` classifies it.

That classifier matches only JSON-parse-specific wording — `JsonParse`,
`Unexpected character`, `Malformed JSON`, `Invalid JSON`. It deliberately does
**not** match the bare word `building`: a `601000` message-building failure
*after* a backend call means the upstream response was unreadable, which is a
`502`, not the caller's fault.

---

## The error contract

Every error from every API, whatever the backend, has exactly this shape:

```json
{
  "error": { "code": "ACCOUNT_NOT_FOUND", "message": "No account matches the supplied account number" },
  "requestId": "9f1c2e4a-55d7-4f0a-9bb1-6a2b7c3d8e11",
  "timestamp": "2026-10-13T09:41:22.108+00:00"
}
```

| HTTP | `error.code` | Meaning |
|---|---|---|
| 400 | `INVALID_REQUEST` | Malformed path parameter, body or field value |
| 404 | `ACCOUNT_NOT_FOUND` | Well-formed account number, no such account |
| 404 | `CUSTOMER_NOT_FOUND` | No such customer upstream |
| 404 | `RESOURCE_NOT_FOUND` | No API resource matches the request |
| 422 | `ELIGIBILITY_CHECK_REJECTED` | The scoring service declined to assess |
| 502 | `BACKEND_ERROR` | Upstream answered, but unusably |
| 503 | `BACKEND_UNAVAILABLE` | Upstream unreachable |
| 503 | `DATA_SOURCE_UNAVAILABLE` | Database unreachable |
| 504 | `BACKEND_TIMEOUT` | Upstream too slow |
| 500 | `INTERNAL_ERROR` | Anything unclassified |

### Why it is identical rather than merely similar

There is exactly one place in the repository where an error body is built:
`Common_ErrorBuilder`. Every API and every fault path sets three properties —
`ERR_HTTP`, `ERR_CODE`, `ERR_MSG` — and delegates:

```
AccountsAPI  ─┐
CustomersAPI ─┼─→ Common_Fault ─→ Common_ErrorBuilder ─→ response
LoansAPI     ─┘                        ↑
                      (APIs also call it directly for validation errors)
```

`Common_Fault` classifies Synapse-level failures (timeout, connection refused,
unreadable response) into contract codes, but only when the API has not
already set one, so an API's own classification always wins.
