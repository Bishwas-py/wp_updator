defmodule WpUpdator do
  @options [ recv_timeout: 30_000,   # 30 seconds
    timeout: 30_000         # 30 seconds
  ]

  @site_url System.get_env("WP_SITE", "")
  @api_base "#{@site_url}/wp-json"
  @wp_application_password System.get_env("WP_APPLICATION_PASSWORD", "")
  @wp_application_username System.get_env("WP_APPLICATION_USERNAME", "")
  @openai_endpoint "https://api.openai.com/v1/chat/completions"
  @openai_api_key System.get_env("OPENAI_API_KEY", "")
  IO.puts("OpenAI API Key: #{@openai_api_key}")

  def get_service_area_pages do
    all_pages = @api_base
    |> get_all_pages()
    IO.puts("Total pages: #{length(all_pages)}")

    all_pages
    |> Enum.filter(&valid_service_area_link?/1)
    |> Task.async_stream(&fetch_and_generate_meta_description(&1), max_concurrency: 22, timeout: 30_000_000)
    # |> Task.async_stream(&delete_wp_post(&1), max_concurrency: 10, timeout: 30_000_000)  # 30 seconds #delete
    |> Enum.to_list()
  end

  defp valid_service_area_link?(page) do
    link = page["link"]
    match = String.starts_with?(link, "#{@site_url}/service-area/")
    match
  end

  defp get_all_pages(base_url, accumulated_pages \\ [], page_num \\ 1) do
    pages_endpoint = "#{base_url}/wp/v2/pages?page=#{page_num}"
    case HTTPoison.get(pages_endpoint) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body, headers: headers}} ->
        data = Jason.decode!(body)
        IO.puts("Try #{page_num} | Total pages: #{length(data)}")
        next_accumulated_pages = accumulated_pages ++ data
        if has_next?(headers) do
          get_all_pages(base_url, next_accumulated_pages, page_num + 1)
        else
          IO.puts("Total pages: #{length(next_accumulated_pages)}")
          next_accumulated_pages
        end
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} when status_code in 400..499 ->
        IO.puts("HTTP request failed (client error): #{body}")
        accumulated_pages
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts("HTTP request failed: #{reason}")
        []
    end
  end

  defp has_next?(headers) do
    Enum.any?(headers, fn {key, value} ->
      key == "x-wp-totalpages" && String.to_integer(value) > 1
    end)
  end

  defp fetch_and_generate_meta_description(page) do
    content = "Title: #{page["title"]["rendered"]}\nContent: #{page["content"]["rendered"]}"
    IO.puts("Link: #{page["link"]} | ID: #{page["id"]}")
    description = request_openai_meta(content)
    IO.puts("Link: #{page["link"]}| Description: #{description}\n")
    updated_page = update_page_excerpt(page, description)
    IO.puts("Updated page: #{page["link"]}")
    updated_page
  end

  def delete_wp_post(post) do
    post_id = post["id"]
    # curl --user "USERNAME:PASSWORD" https://HOSTNAME/wp-json/wp/v2/users?context=edit
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Basic #{Base.encode64("#{@wp_application_username}:#{@wp_application_password}")}"}
    ]

    url = "#{@api_base}/wp/v2/pages/#{post_id}"
    IO.puts("Deleting post: #{post["_id"]}")
    case HTTPoison.delete(url, headers, @options) do
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}}
      when status_code in [200, 201] ->
        IO.puts("Deleted post: #{post_id}")
        Jason.decode!(body)
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts("Failed to delete post: #{reason}")
        %{}
    end

  end

  defp request_openai_meta(content) do
    data = %{
      "model" => "gpt-4o",
      "messages" => [
        %{
          "role" => "system",
          "content" => "Generate an SEO optimized meta description (text only, no html, just text) for this wordpress page content: "
        },
        %{
          "role" => "user",
          "content" => content
        }
      ]
    }

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{@openai_api_key}"}
    ]

    case HTTPoison.post(@openai_endpoint, Jason.encode!(data), headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        %{"choices" => [%{"message" => %{"content" => text}}]} = Jason.decode!(body)
        text
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} when status_code in 400..499 ->
        IO.puts("API request failed (client error): #{body}")
        raise "OpenAI client error"
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} when status_code in 500..599 ->
        IO.puts("API request failed (server error): #{body}")
        raise "OpenAI server error"
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts("OpenAI request failed: #{reason}")
        raise "OpenAI request failed"
    end
  end

  defp update_page_excerpt(page, excerpt) do
    page_id = page["id"]
    data = %{
      excerpt: excerpt
    }

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Basic #{Base.encode64("#{@wp_application_username}:#{@wp_application_password}")}"}
    ]

    url = "#{@api_base}/wp/v2/pages/#{page_id}"

    case HTTPoison.put(url, Jason.encode!(data), headers, @options) do
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}}
      when status_code in [200, 201] ->
        IO.puts("Updated page excerpt: #{page_id}")
        Jason.decode!(body)
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts("Failed to update page excerpt: #{reason}")
        %{}
    end
  end
end
