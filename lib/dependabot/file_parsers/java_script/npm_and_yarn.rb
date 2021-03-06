# frozen_string_literal: true

# See https://docs.npmjs.com/files/package.json for package.json format docs.

require "dependabot/dependency"
require "dependabot/file_parsers/base"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module FileParsers
    module JavaScript
      class NpmAndYarn < Dependabot::FileParsers::Base
        require "dependabot/file_parsers/base/dependency_set"

        DEPENDENCY_TYPES =
          %w(dependencies devDependencies optionalDependencies).freeze
        CENTRAL_REGISTRIES = %w(
          https://registry.npmjs.org
          https://registry.yarnpkg.com
        ).freeze
        GIT_URL_REGEX = %r{
          (?:^|^git.*?|^github:|^bitbucket:|^gitlab:|github\.com/)
          (?<username>[a-z0-9-]+)/
          (?<repo>[a-z0-9_.-]+)
          (
            (?:\#semver:(?<semver>.+))|
            (?:\#(?<ref>.+))
          )?$
        }ix

        def parse
          dependency_set = DependencySet.new
          dependency_set += manifest_dependencies
          dependency_set += yarn_lock_dependencies if yarn_lock
          dependency_set += package_lock_dependencies if package_lock
          dependency_set.dependencies
        end

        private

        def manifest_dependencies
          dependency_set = DependencySet.new

          package_files.each do |file|
            # TODO: Currently, Dependabot can't handle flat dependency files
            # (and will error at the FileUpdater stage, because the
            # UpdateChecker doesn't take account of flat resolution).
            next if JSON.parse(file.content)["flat"]

            DEPENDENCY_TYPES.each do |type|
              deps = JSON.parse(file.content)[type] || {}
              deps.each do |name, requirement|
                requirement = "*" if requirement == ""
                dep = build_dependency(
                  file: file, type: type, name: name, requirement: requirement
                )
                dependency_set << dep if dep
              end
            end
          end

          dependency_set
        end

        def yarn_lock_dependencies
          dependency_set = DependencySet.new
          parsed_yarn_lock.each do |dep|
            next unless dep["version"]

            # TODO: This isn't quite right, as it will only give us one
            # version of each dependency (when in fact there are many)
            dependency_set << Dependency.new(
              name: dep["name"],
              version: dep["version"],
              package_manager: "npm_and_yarn",
              requirements: []
            )
          end
          dependency_set
        end

        def package_lock_dependencies
          dependency_set = DependencySet.new
          parsed_package_lock_json.
            fetch("dependencies", {}).each do |name, details|
              next unless details["version"]

              # TODO: This isn't quite right, as it will only give us one
              # version of each dependency (when in fact there are many)
              dependency_set << Dependency.new(
                name: name,
                version: details["version"],
                package_manager: "npm_and_yarn",
                requirements: []
              )
            end
          dependency_set
        end

        def build_dependency(file:, type:, name:, requirement:)
          return if lockfile? && !version_for(name, requirement)
          return if local_path?(requirement) || non_git_url?(requirement)

          Dependency.new(
            name: name,
            version: version_for(name, requirement),
            package_manager: "npm_and_yarn",
            requirements: [{
              requirement: requirement_for(requirement),
              file: file.name,
              groups: [type],
              source: source_for(name, requirement)
            }]
          )
        end

        def check_required_files
          raise "No package.json!" unless get_original_file("package.json")
        end

        def local_path?(requirement)
          requirement.start_with?("file:")
        end

        def non_git_url?(requirement)
          requirement.include?("://") && !git_url?(requirement)
        end

        def git_url?(requirement)
          requirement.match?(GIT_URL_REGEX)
        end

        def version_for(name, requirement)
          lockfile_version = lockfile_details(name)&.fetch("version", nil)
          return unless lockfile_version
          return lockfile_version.split("#").last if git_url?(requirement)
          return if lockfile_version.include?("://")
          return if lockfile_version.include?("file:")
          return if lockfile_version.include?("#") && !git_url?(requirement)
          lockfile_version
        end

        def source_for(name, requirement)
          return git_source_for(requirement) if git_url?(requirement)

          resolved_url = lockfile_details(name)&.fetch("resolved", nil)

          return unless resolved_url
          return if CENTRAL_REGISTRIES.any? { |u| resolved_url.start_with?(u) }

          url =
            if resolved_url.include?("/~/") then resolved_url.split("/~/").first
            else resolved_url.split("/")[0..2].join("/")
            end

          { type: "private_registry", url: url }
        end

        def requirement_for(requirement)
          return requirement unless git_url?(requirement)
          details = requirement.match(GIT_URL_REGEX).named_captures
          details["semver"]
        end

        def git_source_for(requirement)
          details = requirement.match(GIT_URL_REGEX).named_captures
          {
            type: "git",
            url: "https://github.com/#{details['username']}/#{details['repo']}",
            branch: nil,
            ref: details["ref"] || "master"
          }
        end

        def lockfile_details(name)
          if package_lock && parsed_package_lock_json.dig("dependencies", name)
            parsed_package_lock_json.dig("dependencies", name)
          elsif yarn_lock && parsed_yarn_lock.find { |dep| dep["name"] == name }
            parsed_yarn_lock.find { |dep| dep["name"] == name }
          end
        end

        def parsed_package_lock_json
          JSON.parse(package_lock.content)
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, package_lock.path
        end

        def parsed_yarn_lock
          @parsed_yarn_lock ||=
            SharedHelpers.in_a_temporary_directory do
              dependency_files.
                select { |f| f.name.end_with?("package.json") }.
                each do |file|
                  path = file.name
                  FileUtils.mkdir_p(Pathname.new(path).dirname)
                  File.write(file.name, sanitized_package_json_content(file))
                end
              File.write("yarn.lock", yarn_lock.content)

              project_root = File.join(File.dirname(__FILE__), "../../../..")
              helper_path = File.join(project_root, "helpers/yarn/bin/run.js")

              SharedHelpers.run_helper_subprocess(
                command: "node #{helper_path}",
                function: "parse",
                args: [Dir.pwd]
              )
            end
        rescue SharedHelpers::HelperSubprocessFailed => error
          raise unless error.message == "workspacesRequirePrivateProjects"
          raise Dependabot::DependencyFileNotEvaluatable, error.message
        end

        def package_files
          dependency_files.
            select { |f| f.name.end_with?("package.json") }.
            reject { |f| f.type == "path_dependency" }
        end

        def sanitized_package_json_content(file)
          file.content.
            gsub(/\{\{.*\}\}/, "something"). # {{ name }} syntax not allowed
            gsub("\\ ", " ")                 # escaped whitespace not allowed
        end

        def lockfile?
          yarn_lock || package_lock
        end

        def package_lock
          @package_lock ||= get_original_file("package-lock.json")
        end

        def yarn_lock
          @yarn_lock ||= get_original_file("yarn.lock")
        end
      end
    end
  end
end
