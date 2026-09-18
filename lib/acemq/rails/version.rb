# frozen_string_literal: true

# Copyright 2026 AceMQ.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module AceMQ
  module Rails
    # A version line of its own, deliberately.
    #
    # This gem tracks two release trains: AceMQ's and Rails'. A Rails 8.1 that
    # moves an autoloading hook is a release here and nothing at all in
    # acemq-amqp, and a library release that adds a publishing method is a
    # dependency bump here rather than a new number. Sharing a version with the
    # library would mean one of those two facts had to be lied about.
    VERSION = "0.1.0"
  end
end
