import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post, ApiError } from "@/lib/api";

interface SSOSettings {
  provider: string;
  oidc_issuer_url: string;
  oidc_client_id: string;
  saml_enabled: boolean;
  oidc_group_claim: string;
  group_role_mappings: Record<string, string>;
  updated_at?: string;
}

interface AuthRole {
  name: string;
}

const BUILTIN_ROLES = ["admin", "operator", "worker", "readonly"];

export default function SSOPage() {
  const qc = useQueryClient();
  const { data: settings, isLoading, error } = useQuery({
    queryKey: ["sso-settings"],
    queryFn: () => api<SSOSettings>("/settings/sso"),
  });

  const { data: customRoles } = useQuery({
    queryKey: ["auth-roles"],
    queryFn: () => api<AuthRole[]>("/auth/roles").catch(() => [] as AuthRole[]),
  });

  const allRoles = [
    ...BUILTIN_ROLES,
    ...(customRoles || [])
      .map((r) => r.name)
      .filter((n) => !BUILTIN_ROLES.includes(n)),
  ];

  const [provider, setProvider] = useState("");
  const [oidcIssuerURL, setOidcIssuerURL] = useState("");
  const [oidcClientID, setOidcClientID] = useState("");
  const [samlEnabled, setSamlEnabled] = useState(false);
  const [oidcGroupClaim, setOidcGroupClaim] = useState("groups");
  const [groupMappings, setGroupMappings] = useState<[string, string][]>([]);
  const [loaded, setLoaded] = useState(false);

  if (settings && !loaded) {
    setProvider(settings.provider);
    setOidcIssuerURL(settings.oidc_issuer_url);
    setOidcClientID(settings.oidc_client_id);
    setSamlEnabled(settings.saml_enabled);
    setOidcGroupClaim(settings.oidc_group_claim || "groups");
    const entries = Object.entries(settings.group_role_mappings || {});
    setGroupMappings(entries.length > 0 ? entries : []);
    setLoaded(true);
  }

  const saveMutation = useMutation({
    mutationFn: () => {
      const mappingsObj: Record<string, string> = {};
      for (const [group, role] of groupMappings) {
        const g = group.trim();
        if (g && role) mappingsObj[g] = role;
      }
      return post("/settings/sso", {
        provider,
        oidc_issuer_url: oidcIssuerURL,
        oidc_client_id: oidcClientID,
        saml_enabled: samlEnabled,
        oidc_group_claim: oidcGroupClaim,
        group_role_mappings: mappingsObj,
      });
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["sso-settings"] });
    },
  });

  const addMapping = () => setGroupMappings([...groupMappings, ["", "readonly"]]);
  const removeMapping = (i: number) =>
    setGroupMappings(groupMappings.filter((_, idx) => idx !== i));
  const updateMapping = (i: number, field: 0 | 1, value: string) => {
    const next = [...groupMappings] as [string, string][];
    next[i] = [...next[i]] as [string, string];
    next[i][field] = value;
    setGroupMappings(next);
  };

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

  const inputClass =
    "w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground";

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">SSO Configuration</h1>
        <p className="text-sm text-muted-foreground">
          Configure single sign-on for your Corvo instance.
        </p>
      </div>

      <div className="rounded-lg border border-border/50 bg-muted/30 p-4 text-sm text-muted-foreground space-y-2">
        <p>
          SSO is{" "}
          <strong className="text-foreground">instance-wide</strong> — all
          namespaces share the same identity provider.
        </p>
        <p>
          Clients authenticate with OIDC ID tokens via the{" "}
          <code className="rounded bg-muted px-1 py-0.5 text-xs">
            Authorization: Bearer &lt;token&gt;
          </code>{" "}
          header.
        </p>
        <p>
          <strong className="text-foreground">Recommended:</strong> configure{" "}
          <em>group-to-role mappings</em> below to map your IdP groups to Corvo
          roles — no custom claims needed.
        </p>
        <p>
          <strong className="text-foreground">Advanced:</strong> alternatively,
          add custom claims{" "}
          <code className="rounded bg-muted px-1 py-0.5 text-xs">
            corvo_role
          </code>
          ,{" "}
          <code className="rounded bg-muted px-1 py-0.5 text-xs">
            corvo_roles
          </code>
          ,{" "}
          <code className="rounded bg-muted px-1 py-0.5 text-xs">
            corvo_namespace
          </code>{" "}
          directly in your IdP token. Custom claims take priority over group
          mappings.
        </p>
      </div>

      <div className="rounded-lg border border-border bg-card p-4 space-y-4 max-w-lg">
        <div>
          <label className="block text-sm font-medium text-muted-foreground mb-1">
            Provider
          </label>
          <select
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
            className={inputClass}
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
                className={inputClass}
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
                className={inputClass}
              />
            </div>

            <hr className="border-border/50" />

            <div>
              <label className="block text-sm font-medium text-muted-foreground mb-1">
                Group claim name
              </label>
              <input
                type="text"
                value={oidcGroupClaim}
                onChange={(e) => setOidcGroupClaim(e.target.value)}
                placeholder="groups"
                className={inputClass}
              />
              <p className="text-xs text-muted-foreground mt-1">
                The OIDC token claim that contains group membership. Most IdPs
                use &quot;groups&quot;.
              </p>
            </div>

            <div>
              <label className="block text-sm font-medium text-muted-foreground mb-2">
                Group-to-role mappings
              </label>
              {groupMappings.length === 0 && (
                <p className="text-xs text-muted-foreground mb-2">
                  No mappings configured. Users without custom claims will get
                  the &quot;readonly&quot; role.
                </p>
              )}
              <div className="space-y-2">
                {groupMappings.map(([group, role], i) => (
                  <div key={i} className="flex items-center gap-2">
                    <input
                      type="text"
                      value={group}
                      onChange={(e) => updateMapping(i, 0, e.target.value)}
                      placeholder="IdP group name"
                      className="flex-1 rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
                    />
                    <select
                      value={role}
                      onChange={(e) => updateMapping(i, 1, e.target.value)}
                      className="rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
                    >
                      {allRoles.map((r) => (
                        <option key={r} value={r}>
                          {r}
                        </option>
                      ))}
                    </select>
                    <button
                      type="button"
                      onClick={() => removeMapping(i)}
                      className="rounded px-2 py-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
                      title="Remove mapping"
                    >
                      &times;
                    </button>
                  </div>
                ))}
              </div>
              <button
                type="button"
                onClick={addMapping}
                className="mt-2 rounded-lg border border-dashed border-border px-3 py-1 text-xs text-muted-foreground hover:text-foreground hover:border-foreground/30 transition-colors"
              >
                + Add mapping
              </button>
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
