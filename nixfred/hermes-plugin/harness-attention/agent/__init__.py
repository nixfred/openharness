"""harness-attention: register the tool, the /attention slash command and the bundled skill.

Format per https://hermes-agent.nousresearch.com/docs/developer-guide/plugins (register(ctx),
ctx.register_tool, ctx.register_command, ctx.register_skill).
"""
from pathlib import Path

from . import schemas, tools


def register(ctx):
    url = ctx.get_config("attention_url", default="http://127.0.0.1:18473/api/attention")
    ctx.set_config("attention_url", url)
    tools.configure(url)

    ctx.register_tool(
        name="harness_attention",
        toolset="harness",
        schema=schemas.HARNESS_ATTENTION,
        handler=tools.harness_attention,
    )
    ctx.register_command(
        "attention",
        handler=tools.attention_command,
        description="Who needs me? Agents waiting, needing permission, failed, plus collision alerts",
    )
    skills_dir = Path(__file__).parent / "skills"
    if skills_dir.is_dir():
        for child in sorted(skills_dir.iterdir()):
            skill_md = child / "SKILL.md"
            if child.is_dir() and skill_md.exists():
                ctx.register_skill(child.name, skill_md)
