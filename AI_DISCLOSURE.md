---
tools-used:
  - OpenCode
models-used:
  - claude-opus-4-8
  - claude-sonnet-4-6
  - claude-haiku-4-5
  - gpt-5.4
providers:
  - Anthropic
  - OpenAI
scope:
  human-authored: >
    Repository policy and governance text, and final human review of
    all merged changes.
  ai-generated: >
    Bicep infrastructure templates (aifapim.bicep, modules/,
    *.biceparam), APIM policy XML (apim_policies/), API definitions
    (api_definitions/), and example scripts (examples/) — all with
    human review and validation.
last-updated: 2026-07-14
---

# AI Disclosure

This file describes how AI tools are used in this repository.
It is provided for transparency in accordance with the
[BNL AI Policy](https://intranet.bnl.gov/itd/ai-policy.php)
Transparency principle and
[BNL Generative AI Usage Guidelines](https://intranet.bnl.gov/itd/ai-policy.php).

## Disclosure levels

This repository uses the vocabulary defined by the
[W3C AI Content Disclosure Community Group](https://www.w3.org/community/ai-content-disclosure/)
(a community-group effort, not a ratified W3C standard).
Four levels are defined:

| Level | Meaning |
| --- | --- |
| `none` | No AI tools were used. |
| `ai-assisted` | AI contributed, but a human authored and reviewed. |
| `ai-generated` | AI generated the content; a human reviewed it. |
| `autonomous` | AI produced the content without human review. |

Per the community group's "absence = unknown" principle, files
without an explicit disclosure tag do not imply a specific level.

## Scope of AI use in this repository

**Repository policy and governance text** — including this disclosure
file — is human-authored. The final text is authored and validated by
NSLS-II staff.

**Source code in this repository is largely AI-generated:** AI tools
produce the initial implementation of Bicep templates, APIM policy
XML, API definitions, and example scripts. A human contributor
reviews, tests, and validates all content before merging; the human
remains accountable for every merged change.

## Tools and models

AI assistance in this repository is provided via
**OpenCode** (the NSLS-II-approved AI coding assistant) using
Anthropic models for implementation and OpenAI GPT-5.4 for critical
code review. See the metadata block at the top of this file for the
current list of models.

Per-commit attribution uses the `Assisted-by: AGENT:MODEL` trailer
format. Those per-commit trailers are the authoritative record of
which model contributed to a specific change.

## Purpose of use

AI tools are used to:

- Draft and refactor Bicep infrastructure templates and APIM
  policy XML.
- Draft and review API definitions and example scripts.
- Perform critical code review (GPT-5.4).
- Generate commit messages, code review responses, and test
  scaffolding.

## Input data / datasets

Only repository source files, public documentation, and
non-sensitive prompts are provided as input to AI models.
No sensitive, CUI, export-controlled, PII, HIPAA-regulated, or
classified data is submitted to external AI services, in
accordance with BNL AI Policy Security and Legality principles.

## Limitations and known biases

- LLM output may contain errors, hallucinations, or bias
  inherited from training data.
- All AI-generated content is independently reviewed and validated
  by a human contributor before it is merged.
- The models listed above do not have access to internal BNL
  systems, live data, or non-public information unless explicitly
  provided in a prompt.

## Reviewer disclaimer

AI-generated content in this repository has been reviewed by the
NSLS-II team. Inclusion of AI-generated material does not
substitute for human accountability: the contributing staff member
is responsible for the correctness and appropriateness of every
merged change.
