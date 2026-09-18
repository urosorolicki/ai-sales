# Outreach envelope

The outreach agent writes the middle of the message and nothing else. The
greeting and the signature are assembled in code, from this file, and appended
by WF-05 before the draft is stored - so the text a human approves is the text
that gets sent, not a summary of it.

They are not left to the model on purpose. A greeting is a fact about the
recipient and the system already knows their name; a signature is a claim about
the sender, and a model that writes its own signature is a model inventing a
job title, a company or a promise. `docs/outreach-generation.md` records what
happens when the model is trusted with a field nothing checks.

**Never write anything here that claims a size, a team or a client the business
does not have.** The recipients are European companies, commercial email there
has to identify its sender, and `docs/security.md` rests the whole
legitimate-interest basis on that identification being true.

Edit this file and the next run picks it up. There is no copy inside the
workflow JSON.

## Greeting

`{first_name}` is the recipient's first name as `people.full_name` records it.
It is the only placeholder; anything else in braces is left alone.

```
Hi {first_name},
```

## Signature

The opt-out line is an obligation, not a formality. Until WF-08 exists nothing
reads replies, so a "stop" has to be honoured by hand:

    INSERT INTO suppression_list (email, reason) VALUES ('<address>', 'requested_stop');

```
--
Uroš Orolicki
Ninefold - DevOps, backend and frontend engineering
https://ninefold.com

Not the right person, or not interested? Reply "stop" and you will not hear
from us again.
```
