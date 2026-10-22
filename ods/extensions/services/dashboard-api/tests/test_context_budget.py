"""The prompt sent to the model always fits its real context."""

import asyncio
import math
import random

import pytest

from context_budget import MessageTooLong, fit


def counter():
    """A stand-in for /apply-template + /tokenize: 4 template tokens per
    message plus one token per 4 characters, and a call counter."""
    calls = []

    async def measure(messages):
        calls.append(len(messages))
        return sum(4 + math.ceil(len(m["content"]) / 4) for m in messages)

    return measure, calls


def turns(*contents):
    return [{"role": "user" if i % 2 == 0 else "assistant", "content": text} for i, text in enumerate(contents)]


def run(coro):
    return asyncio.run(coro)


def test_short_history_is_sent_whole():
    measure, _ = counter()
    history = turns("hi", "hello", "how are you", "fine")
    result = run(fit("be brief", history, "and you?", n_ctx=4096, reserve=1024, measure=measure))
    assert result.dropped_messages == 0
    assert [m["content"] for m in result.messages] == ["be brief", "hi", "hello", "how are you", "fine", "and you?"]


def test_oldest_whole_turns_are_dropped_first():
    measure, _ = counter()
    history = turns("a" * 400, "b" * 400, "c" * 400, "d" * 400)  # ~104 tokens each
    result = run(fit(None, history, "now", n_ctx=330, reserve=100, measure=measure))
    assert [m["content"][0] for m in result.messages] == ["c", "d", "n"]
    assert result.dropped_messages == 2 and result.prompt_tokens <= 230


def test_kept_history_never_starts_with_an_answer():
    measure, _ = counter()
    # Keeping "x" (an answer) would fit, but its question does not: the answer
    # is dropped with it rather than sent without the question it answers.
    history = turns("u" * 2000, "x", "y", "z")
    result = run(fit(None, history, "q3", n_ctx=500, reserve=100, measure=measure))
    assert [m["content"] for m in result.messages] == ["y", "z", "q3"]


def test_a_message_too_long_on_its_own_is_refused_with_numbers():
    measure, _ = counter()
    with pytest.raises(MessageTooLong) as refused:
        run(fit("system", [], "x" * 20000, n_ctx=4096, reserve=1024, measure=measure))
    assert refused.value.budget == 3072 and refused.value.prompt_tokens > 3072


def test_a_reserve_that_leaves_no_prompt_room_is_a_programming_error():
    measure, _ = counter()
    with pytest.raises(ValueError):
        run(fit(None, [], "hi", n_ctx=512, reserve=512, measure=measure))


def test_two_hundred_turns_on_a_4096_context_still_answer():
    measure, calls = counter()
    history = turns(*[f"message {i} " * 30 for i in range(400)])
    result = run(fit("system", history, "latest", n_ctx=4096, reserve=1024, measure=measure))
    assert result.prompt_tokens <= 3072 and result.dropped_messages > 0
    assert len(calls) <= math.ceil(math.log2(200)) + 2  # binary search, not one probe per turn


def test_random_histories_always_fit_and_keep_the_most_recent_turns():
    rng = random.Random(7968)
    for _ in range(1000):
        measure, _ = counter()
        n_ctx = rng.choice([512, 1024, 4096])
        reserve = n_ctx // 4
        history = turns(*["w" * rng.randint(1, 1200) for _ in range(rng.randrange(0, 40, 2))])
        user = "u" * rng.randint(1, 600)
        try:
            result = run(fit(None, history, user, n_ctx=n_ctx, reserve=reserve, measure=measure))
        except MessageTooLong as refused:
            assert refused.prompt_tokens > n_ctx - reserve
            continue
        assert result.prompt_tokens <= n_ctx - reserve
        kept = result.messages[:-1]
        assert kept == history[len(history) - len(kept):]  # a suffix of the saved history
        assert not kept or kept[0]["role"] == "user"
        if kept != history:  # maximal: the previous complete turn would not fit
            start = len(history) - len(kept) - 2
            longer = history[start:] + [{"role": "user", "content": user}]
            assert run(measure(longer)) > n_ctx - reserve
