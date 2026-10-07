defmodule Dran.Skills.Builtin.Parser do
  @moduledoc """
  El parseo de un `SKILL.md` de built-in, en COMPILE time: frontmatter (name +
  description) y cuerpo, con el contrato del wire validado en el momento de
  compilar.

  Vive en su propio módulo porque `Dran.Skills.Builtin` lo usa al evaluar sus
  atributos de módulo, y un módulo no puede llamar a sus propias funciones
  mientras se está definiendo.

  Un archivo que no cumple el contrato ABORTA la compilación con el archivo y el
  motivo: es más barato (y más honesto) que descubrirlo al servir, cuando el
  changeset del wire lo rechace.
  """

  alias Dran.Skills.Skill

  # El shape del archivo: frontmatter YAML entre dos `---` y el cuerpo después.
  # El `---` de cierre se busca pegado al inicio para que una regla horizontal
  # del markdown no se lea como el fin del frontmatter.
  @frontmatter ~r/\A---\r?\n(?<front>.*?)\r?\n---\r?\n(?<body>.*)\z/s

  @doc "Parsea y valida un archivo: `%{slug, name, description, body}`."
  def parse!(file) when is_binary(file) do
    case Regex.named_captures(@frontmatter, File.read!(file)) do
      %{"front" => front, "body" => body} ->
        definition!(file, front_value(front, "name"), front_value(front, "description"), body)

      nil ->
        raise """
        #{file}: no frontmatter found.

        A built-in skill must start with `---`, then `name:` and `description:`,
        then `---` and the body.
        """
    end
  end

  defp definition!(file, nil, _description, _body) do
    raise "#{file}: the frontmatter has no `name:` — the name IS the wire slug."
  end

  defp definition!(file, _name, nil, _body) do
    raise "#{file}: the frontmatter has no `description:` — it is the line an agent sees in its index."
  end

  defp definition!(file, name, description, body) do
    description = unquote_description(description)
    body = String.trim_leading(body, "\n")

    validate_name_format!(file, name)
    validate_dir!(file, Path.basename(Path.dirname(file)), name)
    validate_description!(file, description)
    validate_body!(file, body)

    %{slug: name, name: name, description: description, body: body}
  end

  defp front_value(front, key) do
    case Regex.run(~r/^#{key}:\s*(?<value>.*)$/m, front) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  # El frontmatter es YAML: la descripción va citada y las comillas no son parte
  # del valor. Se desescapa lo que se escapó al escribirla.
  defp unquote_description(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp validate_name_format!(file, name) do
    unless Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) and byte_size(name) <= Skill.name_max() do
      raise """
      #{file}: `name: #{name}` is not a valid wire slug.

      Expected a lowercase identifier starting with a letter (a-z, 0-9, _ and -),
      at most #{Skill.name_max()} characters. The name IS the address an agent
      calls: `dran_skill(slug)`.
      """
    end
  end

  defp validate_dir!(file, dir, name) do
    unless dir == name do
      raise """
      #{file}: the directory is `#{dir}` but the frontmatter says `name: #{name}`.

      They must match: the slug is the wire address, so a mismatch would serve a
      skill whose address and whose router line disagree.
      """
    end
  end

  defp validate_description!(file, description) do
    if String.length(description) > Skill.description_max() do
      raise """
      #{file}: the description is #{String.length(description)} characters (max #{Skill.description_max()}).

      It is the ONLY line an agent reads in its index; keep the detail in the body.
      """
    end
  end

  defp validate_body!(file, body) do
    {min, max} = Skill.body_limits()

    if byte_size(body) < min or byte_size(body) > max do
      raise "#{file}: the body is #{byte_size(body)} bytes; the wire accepts #{min}..#{max}."
    end
  end
end
