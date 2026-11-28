---
date: '2026-03-18T13:47:00-04:00'
draft: false
title: 'The future of software engineering: My Thoughts - Part 1'
tags: ["AI", "Continuous Delivery"]
author: cheezy
slug: 'tw-retreat-response'
description: "My thoughts on the first category in the Thoughtworks paper The future of software engineering: where the rigor goes when AI writes the code, from my own work."
---

In February 2026, Thoughtworks released an article titled "[The future of software engineering](https://www.thoughtworks.com/content/dam/thoughtworks/documents/report/tw_future%20_of_software_development_retreat_%20key_takeaways.pdf)". It is a great paper and I encourage everyone to read it. The article lists key themes and takeaways from attendees at a retreat they organized. Here is the Executive summary:

> ### Executive summary
> Senior engineering practitioners from major technology companies gathered for a multi-day retreat to confront the questions that matter most as AI transforms software development. The discussions covered more than twenty topics across breakout sessions, but the most significant insights didn’t emerge from one single session. Instead, they surfaced at various intersections; we found that the same concerns kept appearing in different conversations, framed by different people solving different problems.
>
> This publication synthesizes those cross-cutting themes, organized around the patterns that senior leaders need to understand and act on now. The retreat did not produce a single, unified vision of the future, but instead produced something more useful: a map of the fault lines where current practices are breaking and new ones are forming.

The article went on to list ten themes with a time horizon and core insight.

| Theme | Horizon | Core Insight |
|:-------|:---------|:--------------|
| **Where does the rigor go?** | Now | Engineering quality doesn't disappear when AI writes code. It migrates to specs, tests, constraints, and risk management. |
| **From code review to risk tiering** | Now | Code review is being unbundled. Its four functions (mentorship, consistency, correctness, trust) each need a new home. |
| **The productivity/experience paradox** | Now | Developer productivity and developer experience are decoupling. Organizations face hard choices about which to optimize. |
| **Security as afterthought** | Now | Agent security is woefully underdeveloped. Email access alone can enable full account takeover. |
| **The middle loop** | Now–1 yr | A new category of supervisory engineering work is forming between inner-loop coding and outer-loop delivery. Nobody has named it yet. |
| **Cognitive debt** | Now–1 yr | Technical debt is becoming cognitive debt: the gap between system complexity and human understanding. |
| **Agent topologies** | 1–3 yrs | Conway's Law applies to agents too. Enterprise architecture must now account for agent mobility, specialization, and drift. |
| **Knowledge graphs & semantic layers** | 1–3 yrs | Decades-old technologies are suddenly relevant again as the grounding layer for domain-aware agents. |
| **The future of roles** | 1–3 yrs | PM, developer, and designer roles are converging. Staff engineers face new expectations. Juniors are more valuable than ever. |
| **Self-healing systems** | 2–5 yrs | Moving from human incident response to agent-assisted healing requires solving the 'latent knowledge' problem first. |

After listing these ten themes, the article goes on to summarize the findings of the retreat into **eight categories**. I will only discuss the **first category** in this post that covers the first two themes above. I am hoping to have additional posts in this series where I cover the remaining seven categories.

Before going into the first category, I need to say that I completely agree with their findings. Since I have started working with AI driven developement eight months ago, I have realized that the rigor that used to come from writing code and reviewing code has moved elsewhere.

### 1. Where does the rigor go?

This is the first category listed in the article and it states that it was _The single most important question of the retreat. It surfaced in nearly every session._

Then it begins this section with this statement:

> If AI takes over code production, the engineering discipline that used to live in writing and
reviewing code does not disappear; it moves elsewhere. The retreat spent more time on
this question than any other, approaching it from various viewpoints, including code
review, testing, language design, self-healing systems and organizational design.

The article then goes on to list five destinations where the rigor is already moving. They are:

1. Upstream to specification review
2. Into test suites as first-class artifacts
3. Into type systems and constraints
4. Into risk management
5. Into continuous comprehension

In my work, I have seen my rigor move to items 1 and 4 with a little focus on item 2.

#### Upstream to specification review

The article states:

> Several practitioners reported shifting their review efforts from code to the plan that
precedes it.  ...  The logic is straightforward: if an AI generates code from a spec, the spec is now the highest-leverage artifact for catching errors. Bad specs produce bad code at scale.
>
> This has practical implications. Organizations experimenting with spec-driven development report that the specifications themselves need new formats. Traditional user stories are too vague

I started seeing this last September. With my client, we went through several iterations of refining our specifications. We realized then that it was not possible to have our agent write accurate and complete code from a simple prompt. We tried to use traditional user stories, but they did not deliver the level of detail needed for the agent to understand the requirements.

I spent the second half of December experimenting with different datasets and different approaches to deliver that data to an agent in order to drive accuracy. This was the genesis of [Stride](https://stridelikeaboss.com). I discovered that the agent needed a lot of context to be accurate, and that context needed to be delivered just-in-time. 

The outcome of this effort was the [Stride Task](https://cheezyworld.ca/post/what-is-a-task/). **This is my specification**. It contains all the context that the agent needs to be accurate. When these tasks are uploaded to [Stride](https://stridelikeaboss.com) via one of the [Skills](https://code.claude.com/docs/en/skills) that are a part of the [Stride Claude Code Plugin](https://github.com/cheezy/stride/tree/main), they are placed into a _Backlog_ column (my upstream). **This is where my review takes place**. The tasks are not available for agents to begin working until they are moved to the _Ready_ column, so this provides the developer and/or product manager with the opportunity to review and refine the task before it is worked on.

#### Into risk management

The article states:

> Not all code carries the same risk. The retreat discussed tiering code by business blast radius, distinguishing between internal tools, external-facing services and safety-critical systems. This risk mapping determines where human review is essential and where automated verification is sufficient.
>
> ... This moves engineering from a craft model (every line is hand-reviewed) to a risk management model (verification investment matches exposure).

When I started using AI to write code, I reviewed every single diff that the agent generated. The teams I was working with created PRs for every single task. We spent a lot of time reviewing everything. At that time it was fairly common to find some code that we wanted to change. But as the agents got better and as we got better at [providing the guardrails](https://cheezyworld.ca/post/my_dev_environment/) for the agents, we started seeing fewer and fewer issues that needed to be addressed. We eventually reached a point where it was extremely rare for us to find some code that needed changes during our code reviews. We realized we were spending far more time reviewing code than it took the agent to generate the code and the return on that time was very small.

In early January, I was having conversations with a lot of people about how to manage the risk of using AI to write code. I found that others were having the same experience that I had over the past six months. The need to review every line of code that the agent produces becomes less necessary as the agents proved themselves. Understanding this, I built an [optional review process](https://github.com/cheezy/kanban/blob/main/docs/REVIEW-WORKFLOW.md) into the [Stride workflow](https://cheezyworld.ca/post/stride-enhanced-workflow/). This allows the developer and/or product manager to flag individual tasks as needing a human review. Tasks that are flagged are paused once the agent completes the implementation and will not continue until the human has completed their review.

To assist with this review, I added a [**task-reviewer**](https://github.com/cheezy/stride/blob/main/agents/task-reviewer.md) [SubAgent](https://code.claude.com/docs/en/sub-agents) to the Stride plugin. This SubAgent reviews the code once the agent completes the implementation, and compares the code changes to key fields in the task specification. If the code does not match the specification, the SubAgent provides a report to the implementation agent about the shortcomings and asks it to resolve the issues. If the code matches the specification, a [review report](https://cheezyworld.ca/post/review-report/) is attached to the task specification so anybody on the team can see the results of the review.

The final ingredient to my risk management approach is [Stride Hooks](https://github.com/cheezy/kanban/blob/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md). The hooks specify four places in the development workflow (before and after implementation and review) where the agent must run a set of developer defined commands. These hooks are used to force the agent to perform tasks like running test suites, linting, static code analysis, security scanning, and other quality assurance steps. These hooks ensure that the code and tests are always in a working state and the code adheres to the team's standards.

#### Into test suites as first-class artifacts

The article states:

> One of the retreat's most shareable insights was that test-driven development produces dramatically better results from AI coding agents. The mechanism is specific: TDD prevents a failure mode where agents write tests that verify broken behavior. When the tests exist before the code, agents cannot cheat by writing a test that simply confirms whatever incorrect implementation they produced.
>
> This reframes TDD as a form of prompt engineering. The tests become deterministic validation for non-deterministic generation.

I am a long time practitioner of Test Driven Development. When I started having AI write the majority of my code, I faced an internal battle. I wanted to continue practicing TDD, but it was unnatural for the agent to work in that way. I had to step back and realize that it was the [outcome that I wanted to achieve and not the specific practice](https://cheezyworld.ca/post/tdd-with-ai/). I wanted to have well factored code that was thoroughly tested with quality unit tests.

When I designed the [Stride Task](https://cheezyworld.ca/post/what-is-a-task/), I wanted to ensure the specification (task) had everything needed to specify the desired behaviour. Here are a few of the most critical fields:

- `acceptance_criteria` - Definition of done
- `patterns_to_follow` - Code patterns to replicate
- `validation_rules` - Input validation requirements
- `verification_steps` - How to verify completion
- `pitfalls` - What NOT to do
- `testing_strategy` - Comprehensive testing approach

The **task-reviewer** SubAgent detailed in the previous section uses these fields to perform its review. This is my form of specifying the details before implementation and ensuring completeness and correctness after implementation.

### Summary

I have used [Claude](https://code.claude.com/docs/en/overview) to write code nearly every day since August. I have seen its capabilities and accuracy improve dramatically with each new model release. My knowledge of how to guide the agent to produce quality code that addresses the requirements has also improved as Anthropic has provided new tools to help with this. During the past three months, I have dedicated my time to building out tools that address the challenges I face when working with AI coding agents. The challenges I have seen are exactly what is presented in this article. I feel completely validated!

Stay tuned for future posts where I discuss the other seven categories presented in this article.
