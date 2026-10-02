# Public OIDC discovery with a temporary tunnel

The local issuer is `https://localhost:9031`. An external discovery service cannot reach your PC using its own `localhost`. Trusting a certificate in Windows does not make a cloud service trust or reach that endpoint.

Public runtime discovery was verified using a free ngrok endpoint. A new WebApp was subsequently reported working; complete token-validation output for that client was not supplied. No live hostname or account token is included here.

## Configuration outline

1. Use your own ngrok account and assigned HTTPS hostname. Check the [current free limits](https://ngrok.com/docs/pricing-limits/free-plan-limits) and use only features included in your account. Keep the authtoken private.
2. In PF, retain the local Base URL. Add the assigned public virtual hostname and a corresponding OAuth virtual issuer with a blank path. Configure the incoming proxy hostname header as `X-Dhone-Public-Host`, using its last value. Check that a local Token Endpoint Base URL override is not forcing local URLs into public metadata.
3. Copy the [policy example](../examples/ngrok/pf-runtime-policy.example.yml) to a private working file. Replace `YOUR-NGROK-HOSTNAME` with the assigned hostname. The policy removes any incoming custom hostname header, then sets a fixed trusted value and the expected upstream Host.
4. Start the tunnel with verified upstream TLS. Substitute your private paths and assigned hostname:

   ```powershell
   ngrok http https://localhost:9031 `
     --url=https://YOUR-NGROK-HOSTNAME `
     --traffic-policy-file='C:\YourPrivateLab\Dhone-Ngrok-PF.yml' `
     --upstream-tls-verify=true `
     --upstream-tls-verify-cas='C:\YourPrivateLab\certs\pf-runtime.pem' `
     --inspect=false
   ```

5. Fetch `https://YOUR-NGROK-HOSTNAME/.well-known/openid-configuration`. Verify issuer, authorization, token and JWKS URLs all use the public hostname. Independently verify that local discovery still uses the local issuer.
6. Register a separate test client with the exact callback URI required by the testing tool, the intended grant, OIDC policy and eligible ATM. Use Authorization Code with PKCE. Do not weaken the existing desktop client's redirects to accommodate another application.

The placeholder command cannot run unchanged. The ngrok agent can be stopped with Ctrl+C when the exercise ends. If the assigned endpoint is already online, identify and stop the existing tunnel rather than enabling pooling just to hide the collision.

This recipe exposes PF's runtime for an explicit test. It does not publish the admin console or provide an access policy for remote administration. Remote administration remains a separate pending design.

The included PowerShell PKCE client and teaching API intentionally validate the **local** issuer. Their successful results do not validate a public issuer automatically. A public-client POC must check the issuer actually emitted in its tokens and configure its resource server accordingly.

References: ngrok [CLI](https://ngrok.com/docs/gateway/agent/cli), [remove headers](https://ngrok.com/docs/gateway/traffic-policy/actions/remove-headers), [add headers](https://ngrok.com/docs/gateway/traffic-policy/actions/add-headers).
