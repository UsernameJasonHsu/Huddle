import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Brief, WorkItem } from '../types'

// The mod lives at <repo>/.claude/skills/work-items, so the repo is three levels up.
const repoOf = (pluginRoot: string) =>
  pluginRoot.split('\\').join('/').replace(/\/\.claude\/skills\/[^/]+\/?$/, '')
const PANE = 'work-items'
const REFRESH_MS = 15 * 60 * 1000

const brief = atom({ plugin: 'work-items', key: 'brief' } as const, { ok: 'loading' } as Brief, {
  shape: 'brief-1',
})

const short = (ref: string) => ref.split('/').pop() ?? ref
const sev = (source: string) => source.replace(/^(severity|priority)::/, '').split(' ')[0]
const hasOpenMr = (w: WorkItem) => (w.openMrs ?? []).length > 0
const mrText = (w: WorkItem) =>
  (w.openMrs ?? []).map(m => `!${m.iid}${m.draft ? ' (draft)' : ''}`).join(', ')

type Row = { n: number; w: WorkItem }
type Group = { project: string; rows: Row[] }

// Consecutive rows of one project under one heading; `n` is the item's place in the ranked order.
const groupByProject = (rows: Row[]): Group[] => {
  const groups: Group[] = []
  for (const row of rows) {
    const last = groups[groups.length - 1]
    if (last && last.project === row.w.project) last.rows.push(row)
    else groups.push({ project: row.w.project, rows: [row] })
  }

  return groups
}

const statusText = (b: Brief): string => {
  if (b.ok === 'loading') return '📋 work items: loading…'
  if (b.ok === false) return '📋 work items: fetch failed (/work-items)'
  if (b.items.length === 0) return '📋 0 open'
  // "top" is the first item that still needs work; one with an open MR only waits for review or merge.
  const todo = b.items.filter(w => !hasOpenMr(w))
  const inMr = b.items.length - todo.length
  if (inMr === 0) {
    const top = b.items[0]

    return `📋 ${b.items.length} open · top: ${short(top.reference)} (${sev(top.severitySource)}, idle ${top.idleDays}d)`
  }
  if (todo.length === 0) return `📋 0 to do · ${inMr} in MR`
  const top = todo[0]

  return `📋 ${todo.length} to do · ${inMr} in MR · top: ${short(top.reference)} (${sev(top.severitySource)}, idle ${top.idleDays}d)`
}

async function refresh($: EngineInterface): Promise<void> {
  const repo = repoOf($.plugin.root)
  let next: Brief
  try {
    const { stdout, stderr, exitCode } = await $.process.run(
      ['pwsh', '-NoProfile', '-File', `${repo}/scripts/brief-json.ps1`],
      { cwd: repo, timeoutMs: 90_000 },
    )
    next = exitCode === 0 && stdout.trim()
      ? (JSON.parse(stdout) as Brief)
      : { ok: false, error: `brief-json.ps1 exited ${exitCode}: ${stderr.trim().slice(0, 200)}` }
  } catch (err) {
    next = { ok: false, error: `Could not run brief-json.ps1: ${String(err).slice(0, 200)}` }
  }
  await update($, brief, () => next)
  $.ui.status(statusText(next))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'work-items',
      description: 'Show my ranked GitLab work items in a pane (refreshes them)',
    })
    $.ui.status(statusText(await read($, brief)))
    $.clock.after(1, () => void refresh($))
    $.clock.every(REFRESH_MS, () => void refresh($))

    return next(e)
  })

  on('command.run', { command: 'work-items' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Work items' })
    void refresh($)

    return { text: 'Work items pane opened; refreshing.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const b = await read($, brief)

    if (b.ok === 'loading') return <Text dimColor>Loading work items…</Text>
    if (b.ok === false) {
      return (
        <Box flexDirection="column">
          <Text color="red">{b.error}</Text>
          {b.check && <Text dimColor>{b.check}</Text>}
        </Box>
      )
    }

    // Items with an open MR wait for review or merge; they go in a section of their own, after the
    // items that still need work. Every row keeps its number in the one ranked order.
    const rows: Row[] = b.items.map((w, i) => ({ n: i + 1, w }))
    const todo = rows.filter(r => !hasOpenMr(r.w))
    const inMr = rows.filter(r => hasOpenMr(r.w))
    const failed = b.mrLookupFailed ?? []

    const section = (groups: Group[], withMr: boolean) =>
      groups.map(g => (
        <Box flexDirection="column" marginTop={1}>
          <Text bold>▸ {g.project}</Text>
          {g.rows.map(({ n, w }) => (
            <Box flexDirection="column">
              <Text>
                {n}. {short(w.reference)} [{sev(w.severitySource)}] idle {w.idleDays}d
                {w.dueDate ? ` · due ${w.dueDate}` : ''}
                {withMr ? ` · MR ${mrText(w)}` : ''}
              </Text>
              <Text wrap="truncate-end" dimColor>   {w.title}</Text>
            </Box>
          ))}
        </Box>
      ))

    return (
      <Box flexDirection="column">
        <Text dimColor>
          {b.items.length} open · {b.fetchedAt} · ranked: project → severity → idle
        </Text>
        {b.items.length === 0 && <Text>No open work items are assigned to me.</Text>}
        {inMr.length > 0 && (
          <Box marginTop={1}>
            <Text bold color="cyan">To do, no open MR ({todo.length})</Text>
          </Box>
        )}
        {inMr.length > 0 && todo.length === 0 && (
          <Text dimColor>   None: every open work item already has an open MR.</Text>
        )}
        {section(groupByProject(todo), false)}
        {inMr.length > 0 && (
          <Box marginTop={1}>
            <Text bold color="green">MR open, waiting for review or merge ({inMr.length})</Text>
          </Box>
        )}
        {section(groupByProject(inMr), true)}
        {failed.length > 0 && (
          <Box marginTop={1}>
            <Text color="yellow">
              MR lookup failed for {failed.map(short).join(', ')}; shown as having no open MR, not confirmed.
            </Text>
          </Box>
        )}
      </Box>
    )
  })
}
