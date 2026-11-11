#!/usr/bin/env python3
"""A minimal tool-calling agent that talks to omnigate, standard library only.

An agent harness needs nothing special from the gateway: it is an
OpenAI-compatible endpoint (and an Anthropic-compatible one), so any harness
that takes a base URL and an API key works. This script shows the loop
itself, and the three answers a well-behaved client of a gateway handles:

    402 budget_exceeded   the key's budget is spent: stop and say so (retrying
                          cannot help until someone tops the key up)
    429                   a rate limit, the key's or the provider's: wait for
                          `retry-after` and try again
    5xx                   every target failed: back off and try again

Give each agent (or each tenant) its own gateway key: its budget, rate limit
and model list are then the guard rails, enforced by the gateway whatever the
agent does. `x-omnigate-tag` labels the requests of one run or one end user
in the usage feed (see examples/usage_export.py).

Try it against the dev stack (docs/quickstart.md; gateway on :8080, where the
mock provider calls the first tool when the prompt says "use the tool"):

    python examples/agent_client.py "What is 17 times 23? use the tool"

Environment: OMNIGATE_GATEWAY (default http://127.0.0.1:8080), OMNIGATE_KEY
(default: the dev key), OMNIGATE_MODEL (default demo-direct).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

GATEWAY = os.environ.get("OMNIGATE_GATEWAY", "http://127.0.0.1:8080").rstrip("/")
KEY = os.environ.get("OMNIGATE_KEY", "og-unlimited-key")
MODEL = os.environ.get("OMNIGATE_MODEL", "demo-direct")

TOOLS = [{"type": "function", "function": {
    "name": "multiply", "description": "Multiply two numbers.",
    "parameters": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}}}]


def run_tool(name, arguments):
    """The agent's own code. Whatever it returns goes back to the model as text."""
    if name == "multiply":
        return str(arguments.get("a", 0) * arguments.get("b", 0))
    return f"unknown tool {name}"


class BudgetSpent(Exception):
    pass


def complete(messages, tag=None, attempts=5):
    """One model call through the gateway, with the waiting a client owes it."""
    body = json.dumps({"model": MODEL, "messages": messages, "tools": TOOLS}).encode()
    headers = {"authorization": "Bearer " + KEY, "content-type": "application/json"}
    if tag:
        headers["x-omnigate-tag"] = tag
    for attempt in range(attempts):
        request = urllib.request.Request(GATEWAY + "/v1/chat/completions", data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            if e.code == 402:
                raise BudgetSpent(detail)
            if e.code == 429 or e.code >= 500:
                # The gateway passes the provider's `retry-after` on, and sets
                # its own for the key's rate limit.
                try:
                    wait = float(e.headers.get("retry-after", ""))
                except ValueError:
                    wait = 2.0 ** attempt
                time.sleep(min(wait, 30.0))
                continue
            # 400, 401, 403 (model not allowed for this key), 404: not worth repeating.
            raise RuntimeError(f"{e.code}: {detail}")
        except (urllib.error.URLError, OSError):
            time.sleep(min(2.0 ** attempt, 30.0))
    raise RuntimeError(f"no answer after {attempts} attempts")


def run(prompt, tag=None, max_turns=8):
    """The loop: ask, run the tools the model asks for, hand the results back, until it answers in text."""
    messages = [{"role": "user", "content": prompt}]
    for _ in range(max_turns):
        message = complete(messages, tag)["choices"][0]["message"]
        messages.append(message)
        calls = message.get("tool_calls") or []
        if not calls:
            return message.get("content") or ""
        for call in calls:
            try:
                arguments = json.loads(call["function"].get("arguments") or "{}")
            except ValueError:
                arguments = {}
            result = run_tool(call["function"]["name"], arguments)
            print(f"  tool {call['function']['name']}({arguments}) -> {result}", file=sys.stderr)
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": result})
    raise RuntimeError(f"no final answer within {max_turns} turns")


def main():
    prompt = " ".join(sys.argv[1:]) or "What is 17 times 23? use the tool"
    try:
        print(run(prompt, tag=os.environ.get("OMNIGATE_TAG")))
    except BudgetSpent as e:
        sys.exit(f"this key's budget is spent; it needs a top-up before the agent can go on ({e})")
    except RuntimeError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
