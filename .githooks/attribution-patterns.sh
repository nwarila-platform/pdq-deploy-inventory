# Shared by pre-commit and commit-msg: the vocabulary that must never be published.
# Word-bounded so ordinary prose ("solution", "encrypted") cannot trip it.
ATTRIBUTION_RE='\b(claude|codex|opus|fable|sol|gpt|anthropic|openai|llm|agentic)\b'
TRAILER_RE='(co-authored-by|generated with|assisted-by)'
PROCESS_RE='(_handoff|WORK-ORDER\.md|RESTART\.md|ROADMAP\.md)'
EXPECTED_EMAIL='33955773+NWarila@users.noreply.github.com'
