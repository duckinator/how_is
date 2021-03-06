# frozen_string_literal: true

require "inq/version"
require "inq/date_time_helpers"
require "inq/sources/github"
require "inq/text"

module Inq
  module Sources
    class Github
      ##
      # Fetches raw data for GitHub issues.
      class IssueFetcher
        include Inq::DateTimeHelpers

        END_LOOP = :terminate_graphql_loop

        GRAPHQL_QUERY = <<~QUERY
          repository(owner: %{user}, name: %{repo}) {
            %{type}(first: %{chunk_size}%{after_str}, orderBy:{field: CREATED_AT, direction: ASC}) {
              edges {
                cursor
                node {
                  number
                  createdAt
                  closedAt
                  updatedAt
                  state
                  title
                  url
                  labels(first: 100) {
                    nodes {
                      name
                    }
                  }
                }
              }
            }
          }
        QUERY

        CHUNK_SIZE = 100

        attr_reader :type

        # @param issues_source [Issues] Inq::Issues or Inq::Pulls instance for which to fetch issues
        def initialize(issues_source)
          @issues_source = issues_source
          @cache = issues_source.cache
          @github = Sources::Github.new(issues_source.config)
          @repository = issues_source.config["repository"]
          @user, @repo = @repository.split("/", 2)
          @start_date = issues_source.start_date
          @end_date = issues_source.end_date
          @type = issues_source.type
        end

        def data
          return @data if instance_variable_defined?(:@data)

          @data = []
          return @data if last_cursor.nil?

          Inq::Text.print "Fetching #{@repository} #{@issues_source.pretty_type} data."

          @data = @cache.cached("fetch-#{type}") do
            data = []
            after, data = fetch_issues(after, data) until after == END_LOOP
            data.select(&method(:issue_is_relevant?))
          end

          Inq::Text.puts

          @data
        end

        def issue_is_relevant?(issue)
          if !issue["closedAt"].nil? && date_le(issue["closedAt"], @start_date)
            false
          else
            date_ge(issue["createdAt"], @start_date) && date_le(issue["createdAt"], @end_date)
          end
        end

        def last_cursor
          return @last_cursor if instance_variable_defined?(:@last_cursor)

          raw_data = @github.graphql <<~QUERY
            repository(owner: #{@user.inspect}, name: #{@repo.inspect}) {
              #{type}(last: 1, orderBy:{field: CREATED_AT, direction: ASC}) {
                edges {
                  cursor
                }
              }
            }
          QUERY

          edges = raw_data.dig("data", "repository", type, "edges")
          @last_cursor =
            if edges.nil? || edges.empty?
              nil
            else
              edges.last["cursor"]
            end
        end

        def fetch_issues(after, data)
          Inq::Text.print "."

          after_str = ", after: #{after.inspect}" unless after.nil?

          query = build_query(@user, @repo, type, after_str)
          raw_data = @github.graphql(query)
          edges = raw_data.dig("data", "repository", type, "edges")

          data += edge_nodes(edges)

          next_cursor = edges.last["cursor"]
          next_cursor = END_LOOP if next_cursor == last_cursor

          [next_cursor, data]
        end

        def build_query(user, repo, type, after_str)
          format(GRAPHQL_QUERY, {
            user: user.inspect,
            repo: repo.inspect,
            type: type,
            chunk_size: CHUNK_SIZE,
            after_str: after_str,
          })
        end

        def edge_nodes(edges)
          return [] if edges.nil?
          new_data = edges.map { |issue|
            node = issue["node"]
            node["labels"] = node["labels"]["nodes"]

            node
          }

          new_data
        end
      end
    end
  end
end
