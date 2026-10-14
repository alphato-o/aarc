-- Station air-quality snapshots pushed from inside China (CNEMC blocks foreign
-- IPs, so neither the Worker nor the US gateway can read it directly).
-- id: "cities" (nationwide city averages) or "stations:<城市>" (one city's monitors).
CREATE TABLE IF NOT EXISTS air_cn (
  id TEXT PRIMARY KEY,
  payload TEXT NOT NULL,
  fetched_at TEXT NOT NULL
);
