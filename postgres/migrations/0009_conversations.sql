-- 0009_conversations.sql
-- A conversation is a reply thread. `messages` is not in the original table
-- list but the conversation agent cannot work without turn-by-turn history,
-- so it is included here rather than bolted on later.

CREATE TABLE conversations (
    id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id uuid NOT NULL REFERENCES leads (id) ON DELETE CASCADE,

    channel            text NOT NULL DEFAULT 'email' CHECK (channel IN ('email', 'linkedin')),
    external_thread_id text NOT NULL,

    status text NOT NULL DEFAULT 'open' CHECK (status IN (
        'open',
        'awaiting_reply',
        'awaiting_human',
        'escalated',
        'nurture',
        'closed_won',
        'closed_lost',
        'unsubscribed'
    )),

    -- Set when the classifier or the conversation agent hands control back.
    escalation_reason text,

    last_message_at timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT conversations_thread_key UNIQUE (channel, external_thread_id)
);

CREATE TRIGGER conversations_set_updated_at
    BEFORE UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX conversations_lead_id_idx ON conversations (lead_id);
CREATE INDEX conversations_status_idx  ON conversations (status);
CREATE INDEX conversations_last_msg_idx ON conversations (last_message_at DESC);

-- Threads a human still has to look at.
CREATE INDEX conversations_human_queue_idx ON conversations (updated_at)
    WHERE status IN ('awaiting_human', 'escalated');

CREATE TABLE messages (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,

    direction text NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    author    text NOT NULL CHECK (author IN ('prospect', 'agent', 'human')),

    subject text,
    body    text NOT NULL,

    -- Classifier verdict, only meaningful for inbound messages.
    classification text CHECK (classification IS NULL OR classification IN (
        'POSITIVE', 'QUESTION', 'PRICE', 'NOT_NOW',
        'NEGATIVE', 'REFERRAL', 'UNSUBSCRIBE', 'OUT_OF_SCOPE'
    )),
    classification_confidence numeric(3,2)
        CHECK (classification_confidence IS NULL OR classification_confidence BETWEEN 0 AND 1),

    external_message_id text,
    sent_at             timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT messages_classification_is_inbound
        CHECK (classification IS NULL OR direction = 'inbound')
);

CREATE INDEX messages_conversation_idx ON messages (conversation_id, sent_at);
CREATE INDEX messages_classification_idx ON messages (classification)
    WHERE classification IS NOT NULL;
CREATE UNIQUE INDEX messages_external_id_key ON messages (external_message_id)
    WHERE external_message_id IS NOT NULL;

-- Keeps conversations.last_message_at accurate without workflow bookkeeping.
CREATE OR REPLACE FUNCTION touch_conversation_last_message()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    UPDATE conversations
       SET last_message_at = GREATEST(coalesce(last_message_at, NEW.sent_at), NEW.sent_at),
           updated_at      = now()
     WHERE id = NEW.conversation_id;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER messages_touch_conversation
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION touch_conversation_last_message();
