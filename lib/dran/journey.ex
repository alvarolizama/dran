defmodule Dran.Journey do
  @moduledoc """
  Builds the Journey timeline — pages created over time, grouped by period.

  The journey answers: "How has my second brain grown?"
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Brain.Log

  @day 86_400
  @month 30 * @day

  @doc """
  Build the full journey payload for a context.

  Returns:
    %{
      buckets: [%{label, period_key, pages: [%{slug, page_type, created_by}], total, recency, dominant_type}],
      total: integer,
      stats: %{total_pages, by_type, by_creator, busiest_period, busiest_count},
      trajectory: [integer],  # cumulative count per bucket
      axis: %{start: "Jul 2025", end: "Jul 2026"},
      range: %{min_ts, max_ts, granularity}
    }
  """
  def timeline(context_id, _opts \\ []) do
    entries =
      Repo.all(
        from l in Log,
          where: l.context_id == ^context_id and l.action == "page.create",
          order_by: [asc: l.inserted_at],
          select: %{subject: l.subject, details: l.details, inserted_at: l.inserted_at}
      )

    if entries == [] do
      empty_payload()
    else
      min_ts = List.first(entries).inserted_at |> to_unix()
      max_ts = List.last(entries).inserted_at |> to_unix()
      _span = max_ts - min_ts

      granularity = suggest_granularity(min_ts, max_ts)
      buckets = build_buckets(entries, granularity, min_ts, max_ts)
      total = length(entries)

      by_type =
        entries
        |> Enum.map(&Map.get(&1.details, "page_type", "unknown"))
        |> Enum.frequencies()

      by_creator =
        entries
        |> Enum.map(&Map.get(&1.details, "created_by", "unknown"))
        |> Enum.frequencies()

      busiest =
        buckets
        |> Enum.max_by(& &1.total, fn -> %{label: "-", total: 0} end)

      trajectory =
        buckets
        |> Enum.map(& &1.total)
        |> Enum.scan(fn total, acc -> acc + total end)

      %{
        buckets: buckets,
        total: total,
        stats: %{
          total_pages: total,
          by_type: by_type,
          by_creator: by_creator,
          busiest_period: busiest.label,
          busiest_count: busiest.total
        },
        trajectory: trajectory,
        axis: %{
          start: format_axis_date(min_ts),
          end: format_axis_date(max_ts)
        },
        range: %{min_ts: min_ts, max_ts: max_ts, granularity: granularity}
      }
    end
  end

  @doc """
  Suggest the best granularity for a time span.

  - <= 32 days: day
  - <= 18 months: month
  - else: year
  """
  def suggest_granularity(min_ts, max_ts) do
    span = max_ts - min_ts

    cond do
      span <= 32 * @day -> "day"
      span <= 18 * @month -> "month"
      true -> "year"
    end
  end

  @doc """
  Empty payload when no entries exist.
  """
  def empty_payload do
    %{
      buckets: [],
      total: 0,
      stats: %{
        total_pages: 0,
        by_type: %{},
        by_creator: %{},
        busiest_period: nil,
        busiest_count: 0
      },
      trajectory: [],
      axis: %{start: "", end: ""},
      range: %{min_ts: nil, max_ts: nil, granularity: nil}
    }
  end

  @doc """
  Deterministic color for each page_type using golden-angle hue spacing.

  Returns a map of %{type => "#RRGGBB"}.
  """
  def type_colors do
    # Pre-computed colors with golden-angle hue spacing (137.508°)
    # Ensures distinct colors for all 10 page types
    %{
      "note" => "#D36969",
      "concept" => "#D3A369",
      "entity" => "#C4D369",
      "project" => "#7DD369",
      "reference" => "#69D38A",
      "goal" => "#69D3C4",
      "plan" => "#6996D3",
      "todo" => "#7D69D3",
      "comparison" => "#B969D3",
      "query" => "#D369A3"
    }
  end

  # Convert utc_datetime to unix timestamp
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp to_unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp build_buckets(entries, granularity, min_ts, max_ts) do
    entries
    |> Enum.group_by(fn e -> period_key(e.inserted_at, granularity) end)
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, items} ->
      ts = key_to_timestamp(key, granularity)
      rec = if max_ts > min_ts, do: (ts - min_ts) / (max_ts - min_ts), else: 1.0

      pages =
        Enum.map(items, fn e ->
          %{
            slug: e.subject,
            page_type: Map.get(e.details, "page_type", "unknown"),
            created_by: Map.get(e.details, "created_by", "unknown"),
            inserted_at: e.inserted_at
          }
        end)

      dominant_type =
        pages
        |> Enum.frequencies_by(& &1.page_type)
        |> Enum.max_by(fn {_, v} -> v end, fn -> {"unknown", 0} end)
        |> elem(0)

      %{
        label: period_label(ts, granularity),
        period_key: key,
        ts: ts,
        pages: pages,
        total: length(items),
        recency: rec,
        dominant_type: dominant_type
      }
    end)
  end

  defp period_key(%DateTime{} = dt, "day"), do: {dt.year, dt.month, dt.day}
  defp period_key(%DateTime{} = dt, "month"), do: {dt.year, dt.month}
  defp period_key(%DateTime{} = dt, "year"), do: {dt.year}

  defp period_key(%NaiveDateTime{} = ndt, granularity) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    period_key(dt, granularity)
  end

  defp key_to_timestamp({y, m, d}, "day"),
    do: DateTime.new!(Date.new!(y, m, d), ~T[00:00:00]) |> DateTime.to_unix()

  defp key_to_timestamp({y, m}, "month"),
    do: DateTime.new!(Date.new!(y, m, 1), ~T[00:00:00]) |> DateTime.to_unix()

  defp key_to_timestamp({y}, "year"),
    do: DateTime.new!(Date.new!(y, 1, 1), ~T[00:00:00]) |> DateTime.to_unix()

  defp period_label(ts, "day") do
    dt = DateTime.from_unix!(ts)
    "#{dt.day} #{month_abbr(dt.month)}"
  end

  defp period_label(ts, "month") do
    dt = DateTime.from_unix!(ts)
    "#{month_abbr(dt.month)} #{dt.year}"
  end

  defp period_label(ts, "year") do
    dt = DateTime.from_unix!(ts)
    "#{dt.year}"
  end

  defp format_axis_date(ts) do
    dt = DateTime.from_unix!(ts)
    "#{month_abbr(dt.month)} #{dt.year}"
  end

  defp month_abbr(m) do
    ~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
    |> Enum.at(m - 1, "?")
  end
end
