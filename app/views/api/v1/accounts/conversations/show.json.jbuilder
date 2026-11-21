json.partial! 'api/v1/conversations/partials/conversation', formats: [:json], conversation: @conversation
json.latest_widget_message_proof @conversation.latest_widget_message_proof if params[:include_latest_widget_message_proof] == '1'
