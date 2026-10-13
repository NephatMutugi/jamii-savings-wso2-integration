# The API Manager layer

How the three integrations are published, secured and throttled. For the
consumer's side — discovering, subscribing and getting a token — see
[devportal.md](devportal.md).

All three APIs are published and callable through the gateway at
`https://localhost:8243`. Definitions live in `apim/apis/<api>/` as apictl
projects — `api.yaml` plus an OpenAPI 3.0.3 document under `Definitions/` — so
the published contract is version-controlled rather than clicked into a UI.

| API | APIM name | Context | Security | Tier |
|---|---|---|---|---|
| Account Balance | `JamiiAccountBalance` | `/jamii/accounts` | OAuth2 | `Gold` |
| Customer Profile | `JamiiCustomerProfile` | `/jamii/customers` | OAuth2 | `Gold` |
| Loan Eligibility | `JamiiLoanEligibility` | `/jamii/loans` | API Key | `SoapBackendGuard` |

---

## Division of responsibility

MI owns protocol translation, backend contracts, validation, error mapping and
masking. APIM owns identity, throttling, discovery and the published contract.

Neither does the other's job: MI has no notion of who the caller is, and the
gateway has no notion of what a `DataServiceFault` means. That split is why
the integrations can be tested directly on `localhost:8290` without auth, and
why adding a consumer-facing concern (a new tier, a new scheme) does not
require rebuilding a CAR.

---

## Security schemes

Two different schemes, deliberately, because the consumers differ:

| API | Scheme | Why |
|---|---|---|
| Account Balance | OAuth2, client credentials | Internal channel consumer — mobile and internet banking — acting as itself, not on behalf of an end user |
| Customer Profile | OAuth2, client credentials | Same consumer pattern |
| Loan Eligibility | API Key | Expected consumer is a partner broker integration; a long-lived key is the lower-friction fit, and it demonstrates a second scheme in the same deployment |

OAuth2 tokens come from APIM's own token endpoint:

```bash
curl -k -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
  -d grant_type=client_credentials https://localhost:9443/oauth2/token
```

The API key is generated per application in the Developer Portal and sent as
an `apikey` header.

---

## Throttling

| API | Tier | Limit |
|---|---|---|
| Account Balance | `Gold` | Stock tier |
| Customer Profile | `Gold` | Stock tier |
| Loan Eligibility | **`SoapBackendGuard`** | **10 requests/minute** |

**Why one tier is different, in one line:** Loan Eligibility is the only API
fronting a shared public SOAP service that Jamii neither controls nor pays
for, so the gateway throttles consumers hard enough to protect that dependency
rather than sizing the limit to Jamii's own capacity.

The tier is a custom subscription policy defined in
`apim/policies/rate-limiting/Subscription-SoapBackendGuard.yaml` with
`stopOnQuotaReach: true` — exceeding it returns 429 rather than being allowed
through and billed.

It must exist in APIM **before** the loans API is imported. An API referencing
an absent tier fails with `900305 The tier name is invalid`, which is why the
pipeline imports the tier first.

Observable:

```bash
for i in $(seq 1 13); do
  curl -sk -o /dev/null -w '%{http_code} ' -H "apikey: $API_KEY" \
    -H 'Content-Type: application/json' \
    -X POST https://localhost:8243/jamii/loans/v1/eligibility \
    -d '{"customerId":1,"monthlyIncome":150000,"monthlyDebt":20000,"requestedAmount":600000,"termMonths":24}'
done
# roughly ten 200s, then 429s
```

The same burst against Account Balance on `Gold` passes untouched.

---

## Custom mediation policy

`apim/policies/correlationIdInjector/` — a request-flow Synapse policy
attached to the balance API's operation.

| File | Contents |
|---|---|
| `correlationIdInjector.yaml` | Policy specification: category, applicable flows, supported gateway |
| `correlationIdInjector.j2` | The Synapse mediation template the gateway executes |

It guarantees `X-Correlation-ID` is set at the gateway edge, validating a
caller-supplied value against `^[A-Za-z0-9-]{8,64}$` and substituting a
generated one otherwise:

```xml
<filter source="$trp:X-Correlation-ID" regex="^[A-Za-z0-9-]{8,64}$">
    <then>
        <property name="gatewayCorrelationSource" value="caller"/>
    </then>
    <else>
        <property name="gatewayCorrelationSource" value="gateway"/>
        <property name="X-Correlation-ID" scope="transport"
                  expression="fn:substring-after(get-property('MessageID'), 'urn:uuid:')"/>
    </else>
</filter>
```

**Why this belongs at the gateway rather than only in MI.** The gateway is the
first hop that sees the request. A request rejected by throttling or
authentication never reaches MI, and without this policy such a rejection has
no identifier to correlate against the consumer's own logs. With it, a 429 and
the integration's logs can be tied to the same trace.

Malformed caller values are replaced rather than passed through, which keeps
attacker-controlled text out of the gateway's logs — the same rule
`Common_InFlow` applies inside MI.

The policy is attached declaratively in `api.yaml`:

```yaml
operationPolicies:
  request:
  - policyName: correlationIdInjector
    policyVersion: v1
    parameters: {}
```

so the pipeline reapplies it on every import, rather than depending on a
Publisher UI action that nothing version-controls.

---

## API Product

`JamiiCoreBanking` v1, context `/jamii/core`, bundling all three APIs.

Included rather than justified away, because the consumer shapes genuinely
differ:

- A **banking channel app** needs balance, profile *and* eligibility, and
  should get one subscription and one set of credentials for the set.
- A **partner broker** needs eligibility alone and should not have to
  subscribe to customer data it has no business reading.

Both are served: the product exists, and the three APIs remain individually
subscribable. Bundling them *only* as a product would have forced the broker
to take all three; publishing them *only* individually would have made the
channel app manage three subscriptions and three sets of keys.

---

## Per-environment configuration

`apim/params/<api>-params.yaml` carries a `dev` and a `prod` block:

```yaml
environments:
  - name: dev
    configs:
      endpoints:
        production:
          url: http://mi:8290/accounts
  - name: prod
    configs:
      endpoints:
        production:
          url: http://mi-prod:8290/accounts
```

The `endpointConfig` block in `api.yaml` holds defaults only. Real values come
from the params file at import time, so promoting an API means changing
parameters rather than editing a definition — which is what makes the
pipeline's dev/prod separation meaningful. `mi` is the Compose service name,
resolvable from the APIM container on the shared `jamii-net` network.

---

## Importing by hand

The pipeline does this automatically; these are the same commands.

```bash
apictl add env dev --apim https://localhost:9443
apictl login dev -u admin -k

# Tier first: the loans API references it.
apictl import policy rate-limiting \
  -f apim/policies/rate-limiting/Subscription-SoapBackendGuard.yaml -e dev -k

for api in account-balance customer-profile loan-eligibility; do
  apictl import api -f "apim/apis/$api" -e dev \
    --params "apim/params/$api-params.yaml" --update --rotate-revision -k
done

# Product last: it references the three APIs.
apictl import api-product -f apim/products/JamiiCoreBanking-v1 \
  -e dev --update-api-product -k
```

`--rotate-revision` matters for anything run repeatedly. Each import creates a
new API revision and APIM caps them (5 by default), after which every import
fails with `900351 Maximum number of revisions per API has reached`. Rotation
drops the oldest instead.

`-k` skips certificate verification, which is needed locally because the
containers use self-signed certificates.

---

## Known limitation: two error formats

The three integrations share one error envelope (`error.code`,
`error.message`, `requestId`, `timestamp`). The gateway's own 401, 403 and 429
responses use APIM's default format instead, so a consumer sees two shapes:
the integration's for backend errors, APIM's for authentication and
throttling.

Aligning them means overriding APIM's `_auth_failure_handler_` and throttle
handler sequences at the gateway — a worthwhile change, but one that modifies
product behaviour for every API on that gateway, not just these three.
