require "httparty"

module Edusign
  class Client
    include HTTParty
    base_uri "https://ext.edusign.fr/v1"

    ALREADY_LOCKED_ERROR_MESSAGE = "Course already locked".freeze
    STUDENT_ALREADY_ADDED_TO_COURSE_ERROR_MESSAGE = "Student already in the list"
    LOCKED_ERROR_MESSAGE = "course locked".freeze

    class BadGatewayError < StandardError; end

    def initialize(edusign_account_api_key)
      @edusign_account_api_key = edusign_account_api_key
    end

    # GROUP

    def group(edusign_group_uid)
      return @group if @group.present?

      response = api :get, "/group/#{edusign_group_uid}"
      @group = response.result
    rescue Response::Error => _e
      nil
    end

    def create_or_update_group(name, student_uids: [], edusign_group_uid: nil)
      payload = {group: {NAME: name, STUDENTS: student_uids}}
      if group(edusign_group_uid).present?
        payload[:group][:ID] = edusign_group_uid
        response = api :patch, "/group", payload.to_json
      else
        response = api :post, "/group", payload.to_json
      end
      raise Response::Error, response.message if response.error?
      response.e
    end

    def add_students_to_group(edusign_group_uid, student_uids)
      group = group(edusign_group_uid)
      group[:STUDENTS] = student_uids
      api :patch, "/group", {"group" => group}.to_json
    end

    def delete_group(edusign_group_uid)
      api :delete, "/group/#{edusign_group_uid}"
    end

    # COURSE

    def course(edusign_course_uid)
      response = api :get, "/course/#{edusign_course_uid}"
      response.result
    end

    def create_course(edusign_group_uid, name, starts_at, ends_at, edusign_teacher_uid, description: nil, api_id: nil)
      payload = {
        course: {
          NAME: name,
          START: starts_at,
          END: ends_at,
          DESCRIPTION: description,
          PROFESSOR: edusign_teacher_uid,
          SCHOOL_GROUP: [edusign_group_uid],
          ZOOM: false,
          API_ID: api_id
        }
      }
      api :post, "/course", payload.to_json
    end

    def update_course(edusign_course_uid, edusign_group_uid, name, starts_at, ends_at, edusign_teacher_uid, description: nil, api_id: nil)
      payload = {
        course: {
          ID: edusign_course_uid,
          NAME: name,
          START: starts_at,
          END: ends_at,
          DESCRIPTION: description,
          PROFESSOR: edusign_teacher_uid,
          SCHOOL_GROUP: [edusign_group_uid],
          ZOOM: false,
          API_ID: api_id
        }
      }
      api :patch, "/course", payload.to_json
    end

    def signature_links_for_course(edusign_course_uid, student_uids: [])
      path = "/course/get-signature-links/#{edusign_course_uid}"
      path += "?studentids=#{student_uids.join(",")}" if student_uids.any?
      response = api :get, path
      response.result
    end

    def lock_course(edusign_course_uid)
      course_on_edusign = course(edusign_course_uid)
      if course_on_edusign[:LOCKED].zero?
        response = api :get, "/course/lock/#{edusign_course_uid}"
        response.body[:result][:link]
      else
        course_on_edusign[:ATTENDANCE_LIST_GENERATED]
      end
    rescue Response::Error => e
      raise e unless e.message == ALREADY_LOCKED_ERROR_MESSAGE
    end

    def delete_course(edusign_course_uid)
      api :delete, "/course/#{edusign_course_uid}"
    end

    def courses(edusign_group_uid: nil)
      path = "/course"
      path += "?groupId=#{edusign_group_uid}" if edusign_group_uid.present?
      response = api :get, path
      response.result
    end

    def add_student_to_course(edusign_course_uid, edusign_student_uid)
      api :put, "/course/attendance/#{edusign_course_uid}", {studentId: edusign_student_uid}.to_json
    rescue EdusignClient::Response::Error => e
      raise e unless e.message == STUDENT_ALREADY_ADDED_TO_COURSE_ERROR_MESSAGE
    end

    # STUDENT

    def create_student(first_name, last_name, email, edusign_group_uids: [])
      payload = {
        student: {
          FIRSTNAME: first_name,
          LASTNAME: last_name,
          EMAIL: email,
          SEND_EMAIL_CREDENTIALS: false,
          GROUPS: edusign_group_uids
        }
      }
      api :post, "/student", payload.to_json
    end

    def update_student(edusign_student_uid, first_name, last_name, email, edusign_group_uids: [])
      payload = {
        student: {
          ID: edusign_student_uid,
          FIRSTNAME: first_name,
          LASTNAME: last_name,
          EMAIL: email,
          SEND_EMAIL_CREDENTIALS: false,
          GROUPS: edusign_group_uids
        }
      }
      api :patch, "/student", payload.to_json
    end

    def create_or_update_student(first_name, last_name, email, edusign_student_uid: nil, edusign_group_uids: [])
      edusign_student = edusign_student_uid.present? ? student_by_uid(edusign_student_uid) : student_by_email(email)
      raise Response::Error, "Student doesn't exist" if edusign_student.nil?
      raise Response::Error, "Student was deleted from edusign" if edusign_student[:HIDDEN] == 1

      update_student(edusign_student[:ID], first_name, last_name, email, edusign_group_uids: edusign_group_uids)
    rescue Response::Error => _e
      create_student(first_name, last_name, email, edusign_group_uids: edusign_group_uids)
    end

    def student_by_uid(edusign_student_uid)
      response = api :get, "/student/#{edusign_student_uid}"
      raise Response::Error, "Student with #{edusign_student_uid} UID does not exist" unless response.ok?

      response.result
    end

    def student_by_email(email)
      response = api(:get, "/student/by-email/#{email}")
      response.result
    end

    # TEACHER

    def teacher_by_uid(edusign_teacher_uid)
      response = api :get, "/professor/#{edusign_teacher_uid}"
      raise Response::Error, "Teacher with #{edusign_teacher_uid} UID does not exist" unless response.ok?

      response.result
    end

    def create_professor(first_name, last_name, email)
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

    def find_or_create_professor(first_name, last_name, email)
      response = api :get, "/professor/by-email/#{email}"
      raise Response::Error, "Professor not found" if response.message == "professor not found"
      raise Response::Error, "Teacher was deleted" if response.result.present? && response.result[:HIDDEN].any? && response.result[:HIDDEN].include?(response.result[:ID])

      response.result
    rescue Response::Error => _e
      response = create_professor(first_name, last_name, email)
      response.result
    end

    def teacher_signature_link_for_course(edusign_course_uid)
      response = api :get, "/course/get-professors-signature-links/#{edusign_course_uid}"
      response.result&.first
    end

    # DOCUMENT

    def student_individual_attendance_sheet_pdf(user, start_date, end_date)
      payload = {
        STUDENT_ID: user.edusign_student_uid,
        DATE_START: start_date.beginning_of_day.iso8601,
        DATE_END: end_date.end_of_day.iso8601
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

      response = Response.new(JSON.parse(request.body, symbolize_names: true))
      raise Response::Error, response.message if response.error? && Rails.env.production?

      response
    rescue RestClient::ExceptionWithResponse => e
      Response.new({status: "error", message: e.message})
    end

    def options(opts = {})
      opts.merge({"Authorization" => "Bearer #{@edusign_account_api_key}", "Content-Type" => "application/json"})
    end

    class Response
      class Error < StandardError; end

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
