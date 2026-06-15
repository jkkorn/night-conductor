import { Action, ActionPanel, Color, Icon, List, Toast, showToast } from "@raycast/api";
import { useEffect, useState } from "react";
import { findStalledSessions, StalledSession } from "./lib/conductor";
import { resumeHeadless } from "./lib/resume";

export default function Command() {
  const [items, setItems] = useState<StalledSession[]>([]);
  const [loading, setLoading] = useState(true);

  async function reload() {
    setLoading(true);
    try {
      setItems(await findStalledSessions());
    } catch (error) {
      await showToast({ style: Toast.Style.Failure, title: "Couldn't read Conductor", message: String(error) });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
  }, []);

  async function resume(session: StalledSession) {
    const toast = await showToast({ style: Toast.Style.Animated, title: `Resuming ${session.title}…` });
    try {
      await resumeHeadless(session.claudeSessionId, session.workspacePath);
      toast.style = Toast.Style.Success;
      toast.title = `${session.title} finished a run`;
      await reload();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Resume failed";
      toast.message = String(error instanceof Error ? error.message : error);
    }
  }

  return (
    <List isLoading={loading} searchBarPlaceholder="Stalled sessions">
      <List.EmptyView icon={Icon.Moon} title="No stalled sessions" description="All quiet — nothing waiting at the limit." />
      {items.map((session) => (
        <List.Item
          key={session.sessionId}
          title={session.title}
          subtitle={session.workspaceName}
          icon={{
            source: session.kind === "transient" ? Icon.Bolt : Icon.Pause,
            tintColor: session.kind === "transient" ? Color.Yellow : Color.Orange,
          }}
          accessories={[
            {
              tag: {
                value: session.kind === "transient" ? "rate-limited" : "usage limit",
                color: session.kind === "transient" ? Color.Yellow : Color.Orange,
              },
            },
          ]}
          actions={
            <ActionPanel>
              <Action title="Resume Now" icon={Icon.Play} onAction={() => resume(session)} />
              <Action.Open title="Open Workspace" target={session.workspacePath} icon={Icon.Folder} />
              <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={reload} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
