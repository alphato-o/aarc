-- Live rows: where in the track he was when the app saw it, and the playlist
-- it played from (the race playlist for viewers is then exact).
ALTER TABLE music_play ADD COLUMN offset_ms INTEGER;
ALTER TABLE music_play ADD COLUMN playlist TEXT;
ALTER TABLE music_play ADD COLUMN playlist_uri TEXT;
