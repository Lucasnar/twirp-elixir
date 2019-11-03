defmodule Twirp.Plug do
  import Plug.Conn

  alias Twirp.Encoder
  alias Twirp.Error

  @content_type "content-type"

  def init([service: service_mod, handler: handler]) when is_atom(service_mod) and is_atom(handler) do
    service_def =
      service_mod.definition()
      |> Norm.conform!(Twirp.Service.s())

    rpc_defs =
      for rpc <- service_def.rpcs,
        do: {"#{rpc.method}", rpc},
        into: %{}

    service_def =
      service_def
      |> Map.put(:rpcs, rpc_defs)
      |> Map.put(:full_name, Twirp.Service.full_name(service_def))

    {service_def, handler}
  end

  def call(%{path_info: ["twirp", full_name, method]}=conn, {%{full_name: full_name}=service, handler}) do
    with {:ok, conn, env} <- validate_req(conn, method, service),
         {:ok, result} <- call_handler(handler, env)
    do
      body =
        result
        |> Encoder.encode(env.rpc.output, env.content_type)

      conn
      |> put_resp_content_type(env.content_type)
      |> send_resp(200, body)
      |> halt()
    else
      {:error, error} ->
        send_error(conn, error)
    end
  end

  def call(conn, _opts) do
    conn
  end

  defp send_error(conn, error) do
    content_type = Encoder.type(:json)
    body = Encoder.encode(error, nil, content_type)

    conn
    |> put_resp_content_type(content_type)
    |> send_resp(Error.code_to_status(error.code), body)
    |> halt()
  end

  defp validate_req(conn, method, %{rpcs: rpcs}) do
    content_type = Enum.at(get_req_header(conn, @content_type), 0)

    cond do
      conn.method != "POST" ->
        {:error, bad_route("HTTP request must be POST", conn)}

      !Encoder.valid_type?(content_type) ->
        {:error, bad_route("Unexpected Content-Type: #{content_type || "nil"}", conn)}

      rpcs[method] == nil ->
        {:error, bad_route("Invalid rpc method: #{method}", conn)}

      # If we've got here we can attempt to decode the response body
      true ->
        decode_body(conn, rpcs[method], content_type)
    end
  end

  defp decode_body(conn, rpc_def, content_type) do
    case apply(Plug.Conn, :read_body, [conn]) do
      {:ok, body, conn} ->
        case Encoder.decode(body, rpc_def.input, content_type) do
          {:ok, input} ->
            env = %{content_type: content_type, rpc: rpc_def, input: input}
            {:ok, conn, env}

          {:error, _e} ->
            msg = "Invalid request body for rpc method: #{rpc_def.method}"
            error = bad_route(msg, conn)
            {:error, error}
        end

      _ ->
        {:error, Error.internal("req_body has already been read or is too large to read")}
    end
  end

  # TODO - Handle the case where rpc handlers raise exceptions internally
  defp call_handler(handler, %{rpc: %{handler_fn: f, output: output}}=env) do
    if function_exported?(handler, f, 2) do
      case apply(handler, f, [env, env.input]) do
        %Error{}=error ->
          {:error, error}

        %{__struct__: s}=resp when s == output ->
          {:ok, resp}

        other ->
          msg = "Handler method #{f} expected to return one of #{output} or Twirp.Error but returned #{inspect other}"
          {:error, Error.internal(msg)}
      end
    else
      {:error, Error.unimplemented("Handler function #{f} is not implemented")}
    end
  end

  defp bad_route(msg, conn) do
    Error.bad_route(msg, twirp_invalid_route: "#{conn.method} #{conn.request_path}")
  end
end

