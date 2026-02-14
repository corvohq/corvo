import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post, ApiError } from "@/lib/api";

interface SSOSettings {
  provider: string;
  oidc_issuer_url: string;
  oidc_client_id: string;
  saml_enabled: boolean;
  updated_at?: string;
}

export default function SSOPage() {
  const qc = useQueryClient();
  const { data: settings, isLoading, error } = useQuery({
    queryKey: ["sso-settings"],
    queryFn: () => api<SSOSettings>("/settings/sso"),
  });

  const [provider, setProvider] = useState("");
  const [oidcIssuerURL, setOidcIssuerURL] = useState("");
  const [oidcClientID, setOidcClientID] = useState("");
  const [samlEnabled, setSamlEnabled] = useState(false);
  const [loaded, setLoaded] = useState(false);

  if (settings && !loaded) {
    setProvider(settings.provider);
    setOidcIssuerURL(settings.oidc_issuer_url);
    setOidcClientID(settings.oidc_client_id);
    setSamlEnabled(settings.saml_enabled);
    setLoaded(true);
  }

  const saveMutation = useMutation({
    mutationFn: () =>
      post("/settings/sso", {
        provider,
        oidc_issuer_url: oidcIssuerURL,
        oidc_client_id: oidcClientID,
        saml_enabled: samlEnabled,
      }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["sso-settings"] });
    },
  });

  if (error instanceof ApiError && error.status === 403) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold">SSO Configuration</h1>
          <p className="text-sm text-muted-foreground">
            Configure single sign-on for your Corvo instance.
          </p>
        </div>
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-6 text-center">
          <p className="text-sm text-yellow-400">
            This feature requires an enterprise license.
          </p>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <p className="py-8 text-center text-sm text-muted-foreground">
        Loading...
      </p>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">SSO Configuration</h1>
        <p className="text-sm text-muted-foreground">
          Configure single sign-on for your Corvo instance.
        </p>
      </div>

      <div className="rounded-lg border border-border/50 bg-muted/30 p-4 text-sm text-muted-foreground space-y-2">
        <p>SSO is <strong className="text-foreground">instance-wide</strong> — all namespaces share the same identity provider.</p>
        <p>Clients authenticate with OIDC ID tokens via the <code className="rounded bg-muted px-1 py-0.5 text-xs">Authorization: Bearer &lt;token&gt;</code> header.</p>
        <p>Required OIDC claims: <code className="rounded bg-muted px-1 py-0.5 text-xs">corvo_namespace</code>, <code className="rounded bg-muted px-1 py-0.5 text-xs">corvo_role</code>, <code className="rounded bg-muted px-1 py-0.5 text-xs">corvo_roles</code> (optional, for custom RBAC roles).</p>
        <p>Your IdP must be configured to include these custom claims in the ID token.</p>
      </div>

      <div className="rounded-lg border border-border bg-card p-4 space-y-4 max-w-lg">
        <div>
          <label className="block text-sm font-medium text-muted-foreground mb-1">
            Provider
          </label>
          <select
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
            className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
          >
            <option value="">None</option>
            <option value="oidc">OIDC</option>
            <option value="saml">SAML Header</option>
          </select>
        </div>

        {provider === "oidc" && (
          <>
            <div>
              <label className="block text-sm font-medium text-muted-foreground mb-1">
                Issuer URL
              </label>
              <input
                type="text"
                value={oidcIssuerURL}
                onChange={(e) => setOidcIssuerURL(e.target.value)}
                placeholder="https://accounts.google.com"
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-muted-foreground mb-1">
                Client ID
              </label>
              <input
                type="text"
                value={oidcClientID}
                onChange={(e) => setOidcClientID(e.target.value)}
                placeholder="your-client-id"
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              />
            </div>
          </>
        )}

        {provider === "saml" && (
          <div className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={samlEnabled}
              onChange={(e) => setSamlEnabled(e.target.checked)}
              className="rounded"
              id="saml-enabled"
            />
            <label htmlFor="saml-enabled" className="text-sm text-foreground">
              Enable SAML Header Authentication
            </label>
          </div>
        )}

        <button
          onClick={() => saveMutation.mutate()}
          disabled={saveMutation.isPending}
          className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50"
        >
          {saveMutation.isPending ? "Saving..." : "Save"}
        </button>

        {saveMutation.isSuccess && (
          <p className="text-sm text-green-400">SSO settings saved.</p>
        )}
      </div>
    </div>
  );
}
