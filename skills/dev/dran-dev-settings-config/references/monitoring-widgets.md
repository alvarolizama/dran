# Instance monitoring widgets (Dran /admin/system)

Recipe for the four monitoring cards (DB, disk, BEAM memory, uptime),
collected in `collect_monitoring/0` on AdminSystemLive and rendered only
after a `refresh_monitoring` event (cards show "—" until then).

- **DB size**: `SELECT pg_database_size(current_database())` via
  `Dran.Repo.query!`; table count from `information_schema.tables` where
  `table_schema = 'public'`.
- **Disk**: `:disksup.get_disk_data()` — requires `:os_mon` in
  `extra_applications` (mix.exs `application/0`), otherwise the call
  crashes. Returns `[{mount, total_kb, used_percent, _}]`; take the first
  row, free = total - used, and guard non-integer rows (exotic platforms).
- **BEAM memory**: `:erlang.memory(:total)` as the whole,
  `processes + ets` as "used"; percent via integer division with a
  zero-denominator guard.
- **Uptime**: `:erlang.statistics(:wall_clock)` ms → d/h/m breakdown;
  sub-line `:erlang.system_info(:process_count)` and
  `:schedulers_online`.
- Tone thresholds: >=90% error, >=75% warning, else success.
- os_mon prints `[os_mon] ... Erlang has closed` noise when the VM shuts
  down (test output, `mix run` exits) — harmless, do not chase it.
