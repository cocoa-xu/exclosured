defmodule Mix.Tasks.PrivateAnalytics.GenCsv do
  @moduledoc """
  Generate a sample CSV file with 1,000,000 rows for the Private Analytics demo.

  The file is written to `priv/static/sample_data.csv` and served as a
  static asset. Skips generation if the file already exists.

  ## Usage

      mix private_analytics.gen_csv
      mix private_analytics.gen_csv --force   # regenerate even if exists
  """

  use Mix.Task

  @shortdoc "Generate sample CSV (1M rows) for the Private Analytics demo"

  @output_path "priv/static/sample_data.csv"
  @row_count 1_000_000

  @first_names ~w(Alice Bob Carol David Eve Frank Grace Hank Iris Jack Karen Leo
    Mia Noah Olivia Paul Quinn Rachel Sam Tara Uma Victor Wendy Xander Yara Zane)

  @last_names ~w(Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez
    Martinez Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson
    Martin Lee Perez Thompson White Harris Sanchez Clark Lewis)

  @departments ~w(Engineering Marketing Sales Operations Finance HR Legal Support
    Product Design Research Data)

  @cities [
    {"New York", "NY"}, {"Los Angeles", "CA"}, {"Chicago", "IL"},
    {"Houston", "TX"}, {"Phoenix", "AZ"}, {"Philadelphia", "PA"},
    {"San Antonio", "TX"}, {"San Diego", "CA"}, {"Dallas", "TX"},
    {"Austin", "TX"}, {"Nashville", "TN"}, {"Denver", "CO"},
    {"Washington", "DC"}, {"Seattle", "WA"}, {"Boston", "MA"},
    {"Portland", "OR"}, {"Atlanta", "GA"}, {"Miami", "FL"}
  ]

  @email_domains ~w(example.org proton.me mail.co company.com corp.net work.io)

  @notes ["Remote worker", "On leave", "Team lead", "New hire", "Contractor",
          "Part-time", "Senior", "Intern", "Manager", ""]

  @impl Mix.Task
  def run(args) do
    force = "--force" in args

    if File.exists?(@output_path) and not force do
      size = File.stat!(@output_path).size
      Mix.shell().info("Sample CSV already exists: #{@output_path} (#{div(size, 1024)} KB)")
      Mix.shell().info("Use --force to regenerate.")
      :ok
    else
      File.mkdir_p!(Path.dirname(@output_path))
      Mix.shell().info("Generating #{@row_count} rows...")

      file = File.open!(@output_path, [:write, :utf8])

      IO.write(file, "id,first_name,last_name,email,phone,ssn,credit_card,department,city,state,salary,age,rating,join_date,notes\n")

      for i <- 1..@row_count do
        IO.write(file, generate_row(i))

        if rem(i, 100_000) == 0 do
          Mix.shell().info("  #{i} / #{@row_count} rows...")
        end
      end

      File.close(file)

      size = File.stat!(@output_path).size
      Mix.shell().info("Done: #{@output_path} (#{div(size, 1024)} KB)")
    end
  end

  defp generate_row(id) do
    first = Enum.random(@first_names)
    last = Enum.random(@last_names)
    domain = Enum.random(@email_domains)
    email = "#{String.downcase(String.first(first))}#{String.downcase(last)}@#{domain}"
    phone = "#{Enum.random(200..999)}-#{Enum.random(100..999)}-#{Enum.random(1000..9999)}"

    # SSN: ~30% chance of having one
    ssn = if :rand.uniform() < 0.3, do: "#{Enum.random(100..899)}-#{Enum.random(10..99)}-#{Enum.random(1000..9999)}", else: ""

    # Credit card: ~40% chance of having one
    cc = if :rand.uniform() < 0.4, do: Enum.map_join(1..16, "", fn _ -> Integer.to_string(:rand.uniform(10) - 1) end), else: ""

    dept = Enum.random(@departments)
    {city, state} = Enum.random(@cities)
    salary = Float.round(40_000 + :rand.uniform() * 80_000, 2)
    age = Enum.random(22..65)
    rating = Float.round(1.0 + :rand.uniform() * 4.0, 1)

    year = Enum.random(2018..2025)
    month = Enum.random(1..12)
    day = Enum.random(1..28)
    join_date = "#{year}-#{String.pad_leading("#{month}", 2, "0")}-#{String.pad_leading("#{day}", 2, "0")}"

    notes = Enum.random(@notes)

    "#{id},#{first},#{last},#{email},#{phone},#{ssn},#{cc},#{dept},#{city},#{state},#{salary},#{age},#{rating},#{join_date},#{notes}\n"
  end
end
