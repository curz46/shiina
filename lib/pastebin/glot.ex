defmodule Glot do

  @base "https://snippets.glot.io"

  def get(url) do
    %{body: body} = HTTPoison.get!(url)
    %{files: [%{content: content}]} = Poison.decode!(body)
    content
  end

  def create(name, language, content) do
    request = %{
      language: language,
      title: name,
      public: false,
      files: [%{name: name, content: content}]
    }
    request = request |> Poison.encode!(pretty: true, indent: 2)

    %{body: body}   = HTTPoison.post!("#{@base}/snippets", request, ["Content-Type": "application/json"])
    %{"url" => url} = Poison.decode!(body)
    String.replace_prefix(url, "https://snippets.", "https://")
  end

end
