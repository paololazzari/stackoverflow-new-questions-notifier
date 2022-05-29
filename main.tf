terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "stackoverflow_tags" {
  type = string
}

variable "email_address" {
  type = string
}

variable "notifier_frequency" {
    type = string
}

data "archive_file" "lambda_zipper" {
  type        = "zip"
  output_path = "${path.root}/.lambda_src/lambda_src.zip"

  source {
    filename = "app.py"
    content  = <<CODE

import requests
from bs4 import BeautifulSoup
import boto3
from botocore.exceptions import ClientError
from datetime import datetime

ses_client = boto3.client('ses')
tags_of_interest = "${var.stackoverflow_tags}".split(",")
sender = recipient = "${var.email_address}"

def send_email(entry, tags):
    
    question_url = entry.find("id").text
    email_subject = "New StackOverflow question!"
    email_charset = "UTF-8"
    
    if len(tags) == 1:
        s_tags = str(tags[0])    
    else:
        s_tags = " and ".join(tags)
    
    message = f"There is a new question for {s_tags}. Check it out <a href={question_url}>here</a>!"
    subject = f"New StackOverflow question for {s_tags}!"
    email_body = "<html><head></head><body><p>" + message + "</p></body></html>"
    
    try:
        response = ses_client.send_email(
            Destination={
                'ToAddresses': [
                    recipient,
                ],
            },
            Message={
                'Body': {
                    'Html': {
                        'Charset': email_charset,
                        'Data': email_body,
                    }
                },
                'Subject': {
                    'Charset': email_charset,
                    'Data': subject,
                },
            },
            Source=sender,
        )
    except ClientError as e:
        print(e.response['Error']['Message'])
    else:
        print("Email sent! Message ID:"),
        print(response['MessageId'])
        
def question_was_asked_today(entry):
    today = datetime.now() 
    question_ask_time = datetime.strptime(entry.find("published").text,'%Y-%m-%dT%H:%M:%SZ')
    if (
        today.day == question_ask_time.day and 
        today.month == question_ask_time.month and 
        today.year == question_ask_time.year
        ):
        return True
    return False

def lambda_handler(event, context):
    
    response = requests.get("https://stackoverflow.com/feeds")
    feed_xml = BeautifulSoup(response.text,features='xml')
    entries = feed_xml.feed.findAll("entry")

    for entry in entries:
        categories = entry.findAll("category")
        if not question_was_asked_today(entry):
            break
        tags = []
        for category in categories:
            tags.append(category["term"])
        tags_of_interest_in_entry = list(set(tags) & set(tags_of_interest))
        if len(tags_of_interest_in_entry) > 0:
            send_email(entry, tags_of_interest_in_entry)
            pass
    return 200
CODE
  }
}

resource "aws_iam_role" "iam_role_for_lambda" {
  name = "iam_role_for_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "iam_policy_for_lambda" {
  name        = "iam_policy_for_lambda"
  path        = "/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ses:SendEmail",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "policy_attachment_to_role" {
  role       = aws_iam_role.iam_role_for_lambda.name
  policy_arn = aws_iam_policy.iam_policy_for_lambda.arn
}

resource "aws_lambda_function" "lambda_function" {

  filename = "${path.root}/.lambda_src/lambda_src.zip"
  function_name = "stackoverflow-new-questions-notifier-lambda"
  role          = aws_iam_role.iam_role_for_lambda.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.8"
  timeout       = 60
  source_code_hash = filebase64sha256("${path.root}/.lambda_src/lambda_src.zip")
  layers = [
      "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p38-requests:2",
      "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p38-beautifulsoup4:1",
      "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p38-lxml:1"
    ]
}

resource "aws_cloudwatch_event_rule" "event_rule" {
  name = "stackoverflow-new-questions-notifier-rule"
  schedule_expression = "rate(${var.notifier_frequency})"
}

resource "aws_cloudwatch_event_target" "event_target" {
  rule      = aws_cloudwatch_event_rule.event_rule.name
  arn       = aws_lambda_function.lambda_function.arn
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.event_rule.arn
}