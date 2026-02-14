import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  getOrg,
  updateOrg,
  listMembers,
  removeMember,
  listApiKeys,
  createApiKey,
  deleteApiKey,
} from "@/lib/api";
import type { Org, OrgMember, ApiKey } from "@/lib/api";
import { Copy, Plus, Trash2 } from "lucide-react";

function timeAgo(dateStr: string): string {
  const d = new Date(dateStr);
  const now = Date.now();
  const seconds = Math.floor((now - d.getTime()) / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function GeneralTab() {
  const queryClient = useQueryClient();
  const { data: org, isLoading } = useQuery({
    queryKey: ["org"],
    queryFn: getOrg,
  });
  const [name, setName] = useState<string | null>(null);

  const saveMutation = useMutation({
    mutationFn: (newName: string) => updateOrg(newName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["org"] });
      toast.success("Organization updated");
    },
    onError: (err) => toast.error(String(err)),
  });

  const displayName = name ?? org?.name ?? "";
  const isDirty = name !== null && name !== org?.name;

  if (isLoading) {
    return <p className="py-8 text-center text-sm text-muted-foreground">Loading...</p>;
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Organization</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div>
            <label className="text-sm font-medium">Name</label>
            <div className="mt-1 flex gap-2">
              <Input
                value={displayName}
                onChange={(e) => setName(e.target.value)}
                placeholder="Organization name"
              />
              <Button
                size="sm"
                disabled={!isDirty || saveMutation.isPending}
                onClick={() => {
                  if (name) saveMutation.mutate(name);
                }}
              >
                {saveMutation.isPending ? "Saving..." : "Save"}
              </Button>
            </div>
          </div>
          {org && (
            <div className="space-y-2 text-sm text-muted-foreground">
              <div>
                <span className="font-medium text-foreground">Org ID:</span>{" "}
                <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">{org.id}</code>
              </div>
              <div>
                <span className="font-medium text-foreground">Endpoint:</span>{" "}
                <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">
                  {window.location.origin}/api/v1
                </code>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function ApiKeysTab() {
  const queryClient = useQueryClient();
  const { data: keys, isLoading } = useQuery({
    queryKey: ["org-api-keys"],
    queryFn: listApiKeys,
  });
  const [newKeyName, setNewKeyName] = useState("");
  const [createdKey, setCreatedKey] = useState<string | null>(null);

  const createMutation = useMutation({
    mutationFn: (keyName: string) => createApiKey(keyName),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ["org-api-keys"] });
      setNewKeyName("");
      if (data.key) {
        setCreatedKey(data.key);
      }
      toast.success("API key created");
    },
    onError: (err) => toast.error(String(err)),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: string) => deleteApiKey(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["org-api-keys"] });
      toast.success("API key deleted");
    },
    onError: (err) => toast.error(String(err)),
  });

  return (
    <div className="space-y-6">
      {createdKey && (
        <Card className="border-green-500/50 bg-green-500/5">
          <CardContent className="pt-6">
            <p className="mb-2 text-sm font-medium">
              Your new API key (copy it now, it won't be shown again):
            </p>
            <div className="flex items-center gap-2">
              <code className="flex-1 rounded bg-muted px-3 py-2 font-mono text-sm break-all">
                {createdKey}
              </code>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  navigator.clipboard.writeText(createdKey);
                  toast.success("Copied to clipboard");
                }}
              >
                <Copy className="h-4 w-4" />
              </Button>
            </div>
            <Button
              variant="ghost"
              size="sm"
              className="mt-2"
              onClick={() => setCreatedKey(null)}
            >
              Dismiss
            </Button>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Create API Key</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex gap-2">
            <Input
              value={newKeyName}
              onChange={(e) => setNewKeyName(e.target.value)}
              placeholder="Key name (e.g. Production)"
              onKeyDown={(e) => {
                if (e.key === "Enter" && newKeyName.trim()) {
                  createMutation.mutate(newKeyName.trim());
                }
              }}
            />
            <Button
              size="sm"
              disabled={!newKeyName.trim() || createMutation.isPending}
              onClick={() => createMutation.mutate(newKeyName.trim())}
            >
              <Plus className="mr-1 h-4 w-4" />
              Create
            </Button>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            API Keys
            {keys && (
              <span className="ml-2 font-normal text-muted-foreground">({keys.length})</span>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="py-4 text-center text-sm text-muted-foreground">Loading...</p>
          ) : !keys || keys.length === 0 ? (
            <p className="py-4 text-center text-sm text-muted-foreground">No API keys yet</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Prefix</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead className="w-12" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {keys.map((key) => (
                  <TableRow key={key.id}>
                    <TableCell className="font-medium">{key.name}</TableCell>
                    <TableCell>
                      <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">
                        {key.prefix}...
                      </code>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {timeAgo(key.created_at)}
                    </TableCell>
                    <TableCell>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => deleteMutation.mutate(key.id)}
                        disabled={deleteMutation.isPending}
                      >
                        <Trash2 className="h-4 w-4 text-destructive" />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function TeamTab() {
  const queryClient = useQueryClient();
  const { data: members, isLoading } = useQuery({
    queryKey: ["org-members"],
    queryFn: listMembers,
  });

  const removeMutation = useMutation({
    mutationFn: (id: string) => removeMember(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["org-members"] });
      toast.success("Member removed");
    },
    onError: (err) => toast.error(String(err)),
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm">
          Team Members
          {members && (
            <span className="ml-2 font-normal text-muted-foreground">({members.length})</span>
          )}
        </CardTitle>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <p className="py-4 text-center text-sm text-muted-foreground">Loading...</p>
        ) : !members || members.length === 0 ? (
          <p className="py-4 text-center text-sm text-muted-foreground">No team members</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Email</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Joined</TableHead>
                <TableHead className="w-12" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {members.map((member) => (
                <TableRow key={member.id}>
                  <TableCell className="font-medium">{member.name}</TableCell>
                  <TableCell className="text-muted-foreground">{member.email}</TableCell>
                  <TableCell>
                    <Badge variant={member.role === "owner" ? "default" : "secondary"}>
                      {member.role}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {timeAgo(member.created_at)}
                  </TableCell>
                  <TableCell>
                    {member.role !== "owner" && (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => removeMutation.mutate(member.id)}
                        disabled={removeMutation.isPending}
                      >
                        <Trash2 className="h-4 w-4 text-destructive" />
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}

export default function SettingsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Settings</h1>
        <p className="text-sm text-muted-foreground">
          Manage your organization, API keys, and team.
        </p>
      </div>

      <Tabs defaultValue="general">
        <TabsList>
          <TabsTrigger value="general">General</TabsTrigger>
          <TabsTrigger value="api-keys">API Keys</TabsTrigger>
          <TabsTrigger value="team">Team</TabsTrigger>
        </TabsList>
        <TabsContent value="general">
          <GeneralTab />
        </TabsContent>
        <TabsContent value="api-keys">
          <ApiKeysTab />
        </TabsContent>
        <TabsContent value="team">
          <TeamTab />
        </TabsContent>
      </Tabs>
    </div>
  );
}
