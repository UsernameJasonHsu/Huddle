export type WorkItem = {
  reference: string
  project: string
  title: string
  severitySource: string
  idleDays: number
  dueDate: string | null
  webUrl: string
  // Open MRs that close this item when merged (it waits for review or merge, not for me to start).
  // Optional: a brief stored before this field existed does not have it.
  openMrs?: OpenMr[]
}

export type OpenMr = { iid: number; webUrl: string; draft: boolean }

export type Brief =
  | {
      ok: true
      fetchedAt: string
      host: string
      items: WorkItem[]
      // References whose MR lookup failed; they are shown as having no open MR, unconfirmed.
      mrLookupFailed?: string[]
    }
  | { ok: false; error: string; check?: string }
  | { ok: 'loading' }

declare module 'claude-code' {
  interface PluginState {
    'work-items': { brief: Shaped<Brief> }
  }
}
