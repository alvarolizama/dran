defmodule Dran.Scheduler do
  @moduledoc """
  Quantum-based job scheduler for Dran.

  Jobs are configured in `config/config.exs` (and disabled in `test.exs`).
  """

  use Quantum, otp_app: :dran
end
