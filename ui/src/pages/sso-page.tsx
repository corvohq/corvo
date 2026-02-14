import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post } from "@/lib/api";

interface SSOSettings {
  provider: string;
  oidc_issuer_url: string;
  oidc_client_id: string;
  saml_enabled: boolean;
  updated_at?: string;
}

export default function SSOPage() {
  const qc = useQueryClient();
  const { data: settings, isLoading } = useQuery({
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

      <div className="rounded-lg border border-surface-700 bg-surface-900 p-4 space-y-4 max-w-lg">
        <div>
          <label className="block text-sm font-medium text-surface-400 mb-1">
            Provider
          </label>
          <select
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
            className="w-full rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300"
          >
            <option value="">None</option>
            <option value="oidc">OIDC</option>
            <option value="saml">SAML Header</option>
          </select>
        </div>

        {provider === "oidc" && (
          <>
            <div>
              <label className="block text-sm font-medium text-surface-400 mb-1">
                Issuer URL
              </label>
              <input
                type="text"
                value={oidcIssuerURL}
                onChange={(e) => setOidcIssuerURL(e.target.value)}
                placeholder="https://accounts.google.com"
                className="w-full rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-surface-400 mb-1">
                Client ID
              </label>
              <input
                type="text"
                value={oidcClientID}
                onChange={(e) => setOidcClientID(e.target.value)}
                placeholder="your-client-id"
                className="w-full rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300"
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
            <label htmlFor="saml-enabled" className="text-sm text-surface-300">
              Enable SAML Header Authentication
            </label>
          </div>
        )}

        <button
          onClick={() => saveMutation.mutate()}
          disabled={saveMutation.isPending}
          className="rounded-lg bg-accent-500 px-4 py-2 text-sm font-medium text-white hover:bg-accent-600 transition-colors disabled:opacity-50"
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
