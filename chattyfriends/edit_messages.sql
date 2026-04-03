-- Agregar columna edited_at a messages y group_messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at timestamptz DEFAULT NULL;
ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS edited_at timestamptz DEFAULT NULL;

-- Habilitar replica full para que Realtime envíe eventos UPDATE y DELETE
ALTER TABLE messages REPLICA IDENTITY FULL;
ALTER TABLE group_messages REPLICA IDENTITY FULL;

