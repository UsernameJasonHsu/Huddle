import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'work-items',
  component: 'Pane',
  requestId: 'work-items',
  props: {
    title: 'Work items',
    isFocused: false,
    bodyColumns: 100,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const item = (reference: string, title: string, openMrs: { iid: number; draft: boolean }[]) => ({
  reference,
  project: reference.split('#')[0],
  title,
  severitySource: 'priority::medium (fallback)',
  idleDays: 3,
  dueDate: null,
  webUrl: `https://gitlab.example/${reference}`,
  openMrs: openMrs.map(m => ({ ...m, webUrl: `https://gitlab.example/mr/${m.iid}` })),
})

// What brief-json.ps1 prints; the hooks here stand for the engine beneath the mod.
const start = async ($: any, on: any, brief: unknown) => {
  const statuses: string[] = []
  on('command.register', () => ({ value: { command: 'work-items' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', (_: unknown, e: { text?: string }) => {
    if (e.text) statuses.push(e.text)

    return { value: undefined }
  })
  on('clock.after', () => ({ value: undefined }))
  on('clock.every', () => ({ value: undefined }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('process.run', () => ({
    value: { exitCode: 0, stdout: JSON.stringify(brief), stderr: '' },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'work-items', args: '' })
  // The command starts the refresh without waiting for it.
  for (let i = 0; i < 50 && !statuses.some(s => !s.includes('loading')); i++) {
    await new Promise(resolve => setTimeout(resolve, 10))
  }

  return statuses
}

test('items with an open MR are listed in a section of their own, keeping their rank', async ($, on) => {
  const statuses = await start($, on, {
    ok: true,
    fetchedAt: '2026-11-12 17:30',
    host: 'gitlab.example',
    mrLookupFailed: [],
    items: [
      item('g/SupportDesk#472', 'Root cause', [{ iid: 558, draft: false }]),
      item('g/SupportDesk#477', 'Export schedule', []),
      item('g/portal#407', 'Search index', [{ iid: 514, draft: true }]),
      item('g/portal#581', 'SSL monitor', []),
    ],
  })

  expect(statuses[statuses.length - 1]).toBe('📋 2 to do · 2 in MR · top: SupportDesk#477 (medium, idle 3d)')

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text ?? '')
  const at = (pattern: RegExp) => texts.findIndex(t => pattern.test(t))

  const todo = at(/To do, no open MR \(2\)/)
  const inMr = at(/MR open, waiting for review or merge \(2\)/)
  expect(todo).toBeGreaterThan(-1)
  expect(inMr).toBeGreaterThan(todo)
  // Rank numbers are the places in the one ranked list, so each section has gaps.
  expect(at(/^2\. SupportDesk#477/)).toBeGreaterThan(todo)
  expect(at(/^2\. SupportDesk#477/)).toBeLessThan(inMr)
  expect(at(/^4\. portal#581/)).toBeLessThan(inMr)
  expect(at(/^1\. SupportDesk#472.*MR !558$/)).toBeGreaterThan(inMr)
  expect(at(/^3\. portal#407.*MR !514 \(draft\)$/)).toBeGreaterThan(inMr)
  await ui.unmount()
})

test('with no open MR anywhere the pane is the single list it always was', async ($, on) => {
  const statuses = await start($, on, {
    ok: true,
    fetchedAt: '2026-11-12 17:30',
    host: 'gitlab.example',
    // A brief from before the MR lookup existed: no openMrs, no mrLookupFailed.
    items: [item('g/SupportDesk#477', 'Export schedule', [])].map(({ openMrs, ...rest }) => rest),
  })

  expect(statuses[statuses.length - 1]).toBe('📋 1 open · top: SupportDesk#477 (medium, idle 3d)')

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text ?? '')
  expect(texts.some(t => /To do, no open MR|MR open, waiting/.test(t))).toBe(false)
  expect(texts.some(t => /^1\. SupportDesk#477/.test(t))).toBe(true)
  await ui.unmount()
})

test('a failed MR lookup is said, not hidden', async ($, on) => {
  await start($, on, {
    ok: true,
    fetchedAt: '2026-11-12 17:30',
    host: 'gitlab.example',
    mrLookupFailed: ['g/portal#581'],
    items: [
      item('g/SupportDesk#472', 'Root cause', [{ iid: 558, draft: false }]),
      item('g/portal#581', 'SSL monitor', []),
    ],
  })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const note = await ui.find({ type: 'Text', text: /MR lookup failed/ })
  expect(note?.text).toBe('MR lookup failed for portal#581; shown as having no open MR, not confirmed.')
  await ui.unmount()
})
