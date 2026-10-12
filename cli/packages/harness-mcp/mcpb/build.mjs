#!/usr/bin/env node
/**
 * Builds harness-mcp.mcpb, Harness's MCP Bundle (github.com/modelcontextprotocol/mcpb): what Claude Desktop installs
 * from a file, and what the Official MCP Registry and Smithery list a local server by. Also writes the server.json
 * to publish it to the registry with.
 *
 *   make mcpb ARGS="0.3.74"                                     # or: node cli/packages/harness-mcp/mcpb/build.mjs 0.3.74
 *
 * The version is the CLI release the bundle is attached to, so the tag defaults to v<version>_cli (`--tag` to
 * override). Into cli/packages/harness-mcp/mcpb/dist/ it writes:
 *   harness-mcp.mcpb  manifest.json from this folder at that version, the npm package's bin.mjs and index.mjs as its
 *                     server, and the app's icon
 *   server.json       the repository's server.json with the version, the asset's URL, its sha256 and the npm
 *                     package's version filled in
 * and prints the sha256. It uploads and publishes nothing; docs/research/2026-10-11-listing-submissions.md has the
 * steps that do.
 *
 * Its server is the npm package's (`npx -y @autonomous-ai/harness-mcp`): it runs `harness mcp` from the installed CLI,
 * or, where Harness is not installed, offers one tool that says how to install it. A bundle cannot just name
 * `harness`: mcpb refuses a manifest whose entry_point is not a file in the bundle, and an app opened from the Finder
 * starts with launchd's bare PATH, which leaves out ~/.local/bin, where the installer puts `harness`. The wrapper
 * looks there too. Claude Desktop runs a "node" bundle on its own Node, so the person needs none.
 */
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** The mcpb CLI, pinned: `pack` validates the manifest against this version's schemas (manifest_version 0.3). */
export const MCPB = '@anthropic-ai/mcpb@2.1.2'
export const ASSET = 'harness-mcp.mcpb'
export const RELEASES = 'https://github.com/autonomous-ai/openharness/releases/download'

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..', '..', '..', '..')
const wrapper = join(here, '..')
const icon = join(repo, 'desktop', 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset', 'app_icon_512.png')

/** The server.json to publish for one release, from the repository's (which holds placeholders). */
export function releasedServerJson(template, { version, tag, sha256, npmVersion }) {
  const server = structuredClone(template)
  server.version = version
  for (const pkg of server.packages) {
    if (pkg.registryType === 'mcpb') {
      pkg.identifier = `${RELEASES}/${tag}/${ASSET}`
      pkg.fileSha256 = sha256
    }
    if (pkg.registryType === 'npm') pkg.version = npmVersion
  }
  return server
}

function fail(message) {
  console.error(`✗ ${message}`)
  process.exit(1)
}

function main(argv) {
  const usage = 'usage: build.mjs <version X.Y.Z> [--tag <release tag>]   (make mcpb ARGS="0.3.74")'
  const at = argv.indexOf('--tag')
  const tagArg = at >= 0 ? argv[at + 1] : undefined
  const words = argv.filter((word, i) => !(at >= 0 && (i === at || i === at + 1)))
  const version = words[0]
  if (words.length !== 1 || !/^\d+\.\d+\.\d+$/.test(version ?? '') || (at >= 0 && !tagArg)) {
    console.error(usage)
    process.exit(2)
  }
  const tag = tagArg ?? `v${version}_cli`

  for (const file of ['bin.mjs', 'index.mjs', 'package.json']) {
    if (!existsSync(join(wrapper, file))) fail(`${relative(repo, join(wrapper, file))} is missing: the bundle's server is the npm package's.`)
  }
  if (!existsSync(icon)) fail(`The icon is missing: ${relative(repo, icon)}`)
  const npm = JSON.parse(readFileSync(join(wrapper, 'package.json'), 'utf8'))
  const template = JSON.parse(readFileSync(join(repo, 'server.json'), 'utf8'))
  // The registry checks that the npm package names this server (`mcpName`); a mismatch fails only at publish.
  if (npm.mcpName !== template.name) fail(`package.json mcpName ${npm.mcpName} is not server.json's name ${template.name}`)

  const stage = mkdtempSync(join(tmpdir(), 'harness-mcpb-'))
  try {
    const manifest = JSON.parse(readFileSync(join(here, 'manifest.json'), 'utf8'))
    manifest.version = version
    writeFileSync(join(stage, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`)
    mkdirSync(join(stage, 'server'))
    copyFileSync(join(wrapper, 'bin.mjs'), join(stage, 'server', 'bin.mjs'))
    copyFileSync(join(wrapper, 'index.mjs'), join(stage, 'server', 'index.mjs'))
    copyFileSync(icon, join(stage, 'icon.png'))

    const out = join(here, 'dist')
    mkdirSync(out, { recursive: true })
    const bundle = join(out, ASSET)
    rmSync(bundle, { force: true })
    execFileSync('npx', ['-y', MCPB, 'pack', stage, bundle], { stdio: 'inherit' })

    const sha256 = createHash('sha256').update(readFileSync(bundle)).digest('hex')
    const server = join(out, 'server.json')
    writeFileSync(server, `${JSON.stringify(releasedServerJson(template, { version, tag, sha256, npmVersion: npm.version }), null, 2)}\n`)

    console.log('')
    console.log(`✓ ${relative(process.cwd(), bundle)}`)
    console.log(`  sha256 ${sha256}`)
    console.log(`✓ ${relative(process.cwd(), server)} (version ${version}, ${tag}, ${npm.name}@${npm.version})`)
    console.log('')
    console.log('Nothing is uploaded or published. Once the release exists:')
    console.log(`  gh release upload ${tag} ${relative(process.cwd(), bundle)} --repo autonomous-ai/openharness`)
    console.log(`  mcp-publisher publish ${relative(process.cwd(), server)}`)
  } finally {
    rmSync(stage, { recursive: true, force: true })
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main(process.argv.slice(2))
