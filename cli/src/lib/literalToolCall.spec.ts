import { describe, expect, it } from 'vitest'
import { literalToolCall } from './literalToolCall.js'

describe('code-mode literal tool calls', () => {
  it.each([
    'text(await tools.exec_command({cmd: "cargo test", workdir: "/ship-hn"}));',
    "await tools.exec_command({cmd: 'cargo test', workdir: '/ship-hn',});",
    'const result = await tools.exec_command({cmd: `cargo test`, workdir: "/ship-hn", yield_time_ms: 1000}); text(result);',
    '// @exec: {"max_output_tokens":1000}\ntext(await tools.exec_command({"cmd":"cargo test","workdir":"/ship-hn"}));',
  ])('recognizes an unconditional call: %s', source => {
    expect(literalToolCall(source)).toMatchObject({ name: 'exec_command', input: { cmd: 'cargo test', workdir: '/ship-hn' } })
  })
  it.each([
    'if (false) text(await tools.exec_command({cmd:"pwd",workdir:"/fake"}));',
    'text(await tools.exec_command({cmd: command,workdir:"/fake"}));',
    'text(await tools.exec_command({cmd:`cd ${path}`,workdir:"/fake"}));',
    'text(await tools.exec_command({cmd:"pwd",workdir:"/real",workdir:"/fake"}));',
    'text(await tools.exec_command({cmd:"pwd",...overrides}));',
    'const result=await tools.exec_command({cmd:"pwd"}); text({result, another: tool()});',
    'text(await tools.exec_command({cmd:"pwd"})); text(await tools.exec_command({cmd:"pwd"}));',
    'text(await tools.exec_command({cmd:"pwd", workdir:(()=>"/fake")()}));',
  ])('leaves dynamic or conditional code unknown: %s', source => expect(literalToolCall(source)).toBeNull())
  it('does not interpret strings as source, properties, or prototype setters', () => {
    const parsed = literalToolCall('text(await tools.exec_command({cmd:"echo \\\"{workdir: \\\"/fake\\\"}\\\"", workdir:"/real", __proto__: {hidden:true}}));')
    expect(parsed?.input).toMatchObject({ workdir: '/real' })
    expect(Object.getPrototypeOf(parsed?.input)).toBeNull()
  })
})
