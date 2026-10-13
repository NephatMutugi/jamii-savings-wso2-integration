# Discovering and subscribing via the Developer Portal

How a consuming application gets access to the Jamii APIs. These are the steps
actually used to create the demo application and credentials, not a generic
description.

Developer Portal: `https://localhost:9443/devportal`
(self-signed certificate locally, so the browser warning is expected)

## 1. Discover

Sign in, or self-sign-up if the portal allows it. The three APIs are published
and discoverable:

| API | Context | Security |
|---|---|---|
| Jamii Account Balance | `/jamii/accounts` | OAuth2 |
| Jamii Customer Profile | `/jamii/customers` | OAuth2 |
| Jamii Loan Eligibility | `/jamii/loans` | API Key |

They are also grouped as the **JamiiCoreBanking** API Product
(`/jamii/core`). Subscribing to the product gives one subscription and one set
of credentials covering all three, which is what a full banking channel wants.
The APIs remain individually subscribable for a partner that needs only one,
for example a broker integrating loan eligibility alone.

Each API's **Overview** page carries the OpenAPI definition, and **Try Out**
runs live calls against the gateway once a subscription exists.

## 2. Create an application

**Applications → Add New Application**

- Name, for example `jamii-demo-app`
- Per Token Quota: `Unlimited` for the demo. This is the token issuing quota,
  which is separate from the per-API subscription tier that actually throttles
  traffic.
- Save.

## 3. Subscribe

Open each API (or the API Product) and use **Subscriptions → Subscribe**,
selecting the application and a business plan:

| API | Plan used | Why |
|---|---|---|
| Jamii Account Balance | `Gold` | High-volume read used by internal channels |
| Jamii Customer Profile | `Gold` | Same consumer pattern |
| Jamii Loan Eligibility | `SoapBackendGuard` | 10 requests/minute. It fronts a shared public SOAP service that Jamii neither controls nor pays for, so the gateway protects that dependency from consumer load |

## 4. Generate credentials

**Applications → jamii-demo-app → Production Keys**

- **OAuth2 Tokens → Generate Keys** gives a Consumer Key and Secret, used for
  the two OAuth2 APIs.
- **API Key → Generate Key** gives the key used for Loan Eligibility.

## 5. Call the gateway

Exchange the OAuth2 credentials for a token:

```bash
curl -k -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
  -d grant_type=client_credentials https://localhost:9443/oauth2/token
```

Then call the APIs. Note the two different schemes:

```bash
# OAuth2
curl -k -H "Authorization: Bearer $TOKEN" \
  https://localhost:8243/jamii/accounts/v1/1000000001/balance

curl -k -H "Authorization: Bearer $TOKEN" \
  https://localhost:8243/jamii/customers/v1/1

# API key
curl -k -H "apikey: $API_KEY" -H 'Content-Type: application/json' \
  -X POST https://localhost:8243/jamii/loans/v1/eligibility \
  -d '{"customerId":1,"monthlyIncome":150000,"monthlyDebt":20000,"requestedAmount":600000,"termMonths":24}'
```

Calling without credentials returns 401. Exceeding the subscription tier
returns 429: thirteen rapid calls to Loan Eligibility produce roughly ten 200s
and then 429s, while the same burst against Account Balance on Gold passes
untouched.

## Note on error bodies

The three integrations share one error envelope
(`error.code`, `error.message`, `requestId`, `timestamp`). The gateway's own
401, 403 and 429 responses use APIM's default format instead. Aligning those
means overriding APIM's handler sequences; see the README for why that was
left out.
