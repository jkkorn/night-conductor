import { Color, Icon, MenuBarExtra, launchCommand, LaunchType, open } from "@raycast/api";
import { useEffect, useState } from "react";
import { findStalledSessions, StalledSession } from "./lib/conductor";
import { fetchUsage, Usage } from "./lib/usage";

export default function Command() {
  const [usage, setUsage] = useState<Usage>();
  const [stalled, setStalled] = useState<StalledSession[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const [u, s] = await Promise.allSettled([fetchUsage(), findStalledSessions()]);
      if (u.status === "fulfilled") setUsage(u.value);
      if (s.status === "fulfilled") setStalled(s.value);
      setLoading(false);
    })();
  }, []);

  const title = usage ? `${Math.round(usage.fiveHour)}%` : undefined;

  return (
    <MenuBarExtra icon={Icon.Moon} title={title} isLoading={loading} tooltip="Night Conductor">
      <MenuBarExtra.Section title="Claude usage">
        <MenuBarExtra.Item title="5-hour window" subtitle={usage ? `${Math.round(usage.fiveHour)}%` : "—"} />
        <MenuBarExtra.Item title="Weekly budget" subtitle={usage ? `${Math.round(usage.weekly)}%` : "—"} />
      </MenuBarExtra.Section>
      <MenuBarExtra.Section title={`Stalled at the limit (${stalled.length})`}>
        {stalled.length === 0 && <MenuBarExtra.Item title="All quiet" icon={Icon.Moon} />}
        {stalled.map((s) => (
          <MenuBarExtra.Item
            key={s.sessionId}
            title={s.title}
            subtitle={`${s.workspaceName} · ${s.kind === "transient" ? "rate-limited" : "usage limit"}`}
            icon={{ source: Icon.Pause, tintColor: s.kind === "transient" ? Color.Yellow : Color.Orange }}
            onAction={() => open(s.workspacePath)}
          />
        ))}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section>
        <MenuBarExtra.Item
          title="Resume Sessions…"
          icon={Icon.Play}
          onAction={() => launchCommand({ name: "stalled", type: LaunchType.UserInitiated })}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
