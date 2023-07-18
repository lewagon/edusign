require "active_support/configurable"
require "httparty"

module Edusign
  class Client
    include ActiveSupport::Configurable
    include HTTParty
    base_uri "https://ext.edusign.fr/v1"

    ALREADY_LOCKED_ERROR_MESSAGE = "Course already locked".freeze
    STUDENT_ALREADY_ADDED_TO_COURSE_ERROR_MESSAGE = "Student already in the list"
    LOCKED_ERROR_MESSAGE = "course locked".freeze
    COURSE_NOT_FOUND_ERROR_MESSAGE = "No course with this ID found"

    class NoApiKeyError < StandardError; end

    class BadGatewayError < StandardError; end
    class GatewayTimeoutError < StandardError; end

    def initialize(account_api_key: config.account_api_key)
      @account_api_key = account_api_key

      raise NoApiKeyError, "Please provide an Edusing account API key" if @account_api_key.nil?
    end

    # GROUP

    def group(group_uid:)
      raise Response::Error, "Group doesn't exist" if group_uid.blank?

      return @group if @group.present?

      response = api :get, "/group/#{group_uid}"
      @group = response.result
    rescue Response::Error => _e
      nil
    end

    def create_or_update_group(name:, student_uids: [], group_uid: nil)
      payload = {group: {NAME: name, STUDENTS: []}}
      if group_uid.present?
        payload[:group][:ID] = group_uid
        payload[:group][:STUDENTS] = student_uids
        response = api :patch, "/group", payload.to_json
      else
        response = api :post, "/group", payload.to_json
      end
      raise Response::Error, response.message if response.error?

      response
    end

    def add_students_to_group(group_uid:, student_uids:)
      group = group(group_uid: group_uid)
      group[:STUDENTS] = (group[:STUDENTS] + student_uids).uniq
      api :patch, "/group", {"group" => group}.to_json
    end

    def delete_group(group_uid:)
      api :delete, "/group/#{group_uid}"
    end

    # COURSE

    def course(course_uid:)
      response = api :get, "/course/#{course_uid}"
      response.result
    rescue Response::Error => e
      raise e unless e.message == COURSE_NOT_FOUND_ERROR_MESSAGE
    end

    def create_course(group_uid:, name:, starts_at:, ends_at:, teacher_uid:, description: nil, api_id: nil)
      payload = {
        course: {
          NAME: name,
          START: starts_at.iso8601,
          END: ends_at.iso8601,
          DESCRIPTION: description,
          PROFESSOR: teacher_uid,
          SCHOOL_GROUP: [group_uid],
          ZOOM: false,
          API_ID: api_id
        }
      }
      api :post, "/course", payload.to_json
    end

    def update_course(course_uid:, group_uid:, name:, starts_at:, ends_at:, teacher_uid:, description: nil, api_id: nil)
      payload = {
        course: {
          ID: course_uid,
          NAME: name,
          START: starts_at.iso8601,
          END: ends_at.iso8601,
          DESCRIPTION: description,
          PROFESSOR: teacher_uid,
          SCHOOL_GROUP: [group_uid],
          ZOOM: false,
          API_ID: api_id
        }
      }
      api :patch, "/course", payload.to_json
    end

    def signature_links_for_course(course_uid:, student_uids: [])
      path = "/course/get-signature-links/#{course_uid}"
      path += "?studentids=#{student_uids.join(",")}" if student_uids.any?
      response = api :get, path
      response.result
    end

    def lock_course(course_uid:)
      course_on_edusign = course(course_uid: course_uid)
      if course_on_edusign[:LOCKED].zero?
        response = api :get, "/course/lock/#{course_uid}"
        response.body[:result][:link]
      else
        course_on_edusign[:ATTENDANCE_LIST_GENERATED]
      end
    rescue Response::Error => e
      raise e unless e.message == ALREADY_LOCKED_ERROR_MESSAGE
    end

    def delete_course(course_uid:)
      api :delete, "/course/#{course_uid}"
    end

    def courses(group_uid: nil)
      path = "/course"
      path += "?groupId=#{group_uid}" if group_uid.present?
      response = api :get, path
      response.result
    end

    def add_student_to_course(course_uid:, student_uid:)
      api :put, "/course/attendance/#{course_uid}", {studentId: student_uid}.to_json
    rescue Response::Error => e
      raise e unless e.message == STUDENT_ALREADY_ADDED_TO_COURSE_ERROR_MESSAGE
    end

    def send_signature_email(course_uid:)
      students = course(course_uid: course_uid)[:STUDENTS].reject { |student| student[:state] }.map { |student| student[:studentId] }
      api :post, "/course/send-sign-emails", {"course" => course_uid, "students" => students}.to_json
    end

    # STUDENT

    def create_student(first_name:, last_name:, email:, group_uids: [])
      payload = {
        student: {
          FIRSTNAME: first_name,
          LASTNAME: last_name,
          EMAIL: email,
          SEND_EMAIL_CREDENTIALS: false,
          GROUPS: group_uids
        }
      }
      api :post, "/student", payload.to_json
    end

    def update_student(student_uid:, first_name:, last_name:, email:, group_uids: [])
      payload = {
        student: {
          ID: student_uid,
          FIRSTNAME: first_name,
          LASTNAME: last_name,
          EMAIL: email,
          SEND_EMAIL_CREDENTIALS: false,
          GROUPS: group_uids
        }
      }
      api :patch, "/student", payload.to_json
    end

    def create_or_update_student(first_name:, last_name:, email:, student_uid: nil, group_uids: [])
      student = student_uid.present? ? student_by_uid(student_uid: student_uid) : student_by_email(email: email)
      raise Response::Error, "Student doesn't exist" if student.nil?
      raise Response::Error, "Student was deleted from edusign" if student[:HIDDEN] == 1

      update_student(student_uid: student[:ID], first_name: first_name, last_name: last_name, email: email, group_uids: group_uids)
    rescue Response::Error => _e
      create_student(first_name: first_name, last_name: last_name, email: email, group_uids: group_uids)
    end

    def student_by_uid(student_uid:)
      response = api :get, "/student/#{student_uid}"
      raise Response::Error, "Student with #{student_uid} UID does not exist" unless response.ok?

      response.result
    end

    def student_by_email(email:)
      response = api(:get, "/student/by-email/#{email}")
      response.result
    end

    def declare_absence(student_uid:, course_uid:, type:, comment:)
      api :post, "/justified-absence", {
        STUDENT_ID: student_uid,
        COURSE_ID: course_uid,
        TYPE: type,
        COMMENT: comment
      }.to_json
    end

    # TEACHER

    def teacher_by_uid(teacher_uid:)
      response = api :get, "/professor/#{teacher_uid}"
      raise Response::Error, "Teacher with #{teacher_uid} UID does not exist" unless response.ok?

      response.result
    end

    def create_professor(first_name:, last_name:, email:)
      payload = {
        professor: {
          FIRSTNAME: first_name,
          LASTNAME: last_name,
          EMAIL: email
        },
        dontSendCredentials: true
      }
      api :post, "/professor", payload.to_json
    end

    def find_or_create_professor(first_name:, last_name:, email:)
      response = api :get, "/professor/by-email/#{email}"
      raise Response::Error, Response::Error::PROFESSOR_NOT_FOUND_ERROR_MESSAGE if response.message == "professor not found"
      raise Response::Error, Response::Error::PROFESSOR_DELETED_ERROR_MESSAGE if response.result.present? && response.result[:HIDDEN].any? && response.result[:HIDDEN].include?(response.result[:ID])

      response.result
    rescue Response::Error => e
      raise e unless [Response::Error::PROFESSOR_NOT_FOUND_ERROR_MESSAGE, Response::Error::PROFESSOR_DELETED_ERROR_MESSAGE].include?(e.message)

      response = create_professor(first_name: first_name, last_name: last_name, email: email)
      response.result
    end

    def teacher_signature_link_for_course(course_uid:)
      response = api :get, "/course/get-professors-signature-links/#{course_uid}"
      response.result&.first
    end

    # DOCUMENT

    def student_individual_attendance_sheet_pdf(student_uid:, start_date:, end_date:)
      payload = {
        STUDENT_ID: student_uid,
        DATE_START: start_date.iso8601,
        DATE_END: end_date.iso8601
      }
      response = api :post, "/document/student/courses-between-dates", payload.to_json
      response.result[:filename]
    end

    private

    def api(http_method, path, body = {}, opts = {})
      request = if http_method.match?(/^(get|delete)$/)
        self.class.send(http_method, path, headers: options(opts))
      else
        self.class.send(http_method, path, body: body, headers: options(opts))
      end
      raise BadGatewayError, request.message if request.code == 502
      raise GatewayTimeoutError, request.message if request.code == 504

      response = Response.new(JSON.parse(request.body, symbolize_names: true))
      raise Response::Error, response.message if response.error?

      response
    rescue RestClient::ExceptionWithResponse => e
      Response.new({status: "error", message: e.message})
    end

    def options(opts = {})
      opts.merge({"Authorization" => "Bearer #{@account_api_key}", "Content-Type" => "application/json"})
    end

    class Response
      class Error < StandardError
        PROFESSOR_NOT_FOUND_ERROR_MESSAGE = "professor not found".freeze
        PROFESSOR_DELETED_ERROR_MESSAGE = "professor was deleted".freeze
      end

      attr_reader :body

      def initialize(body)
        @body = body
      end

      def status
        body[:status]
      end

      def message
        body[:message]
      end

      def result
        body[:result]
      end

      def ok?
        status == "success"
      end

      def error?
        status == "error"
      end
    end
  end
end
