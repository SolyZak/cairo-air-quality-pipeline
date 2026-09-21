# ---------------------------------------------------------------------------
# The EC2 instance role.
#
# No access keys anywhere -- not on the box, not in .env, not in GitHub. The
# instance assumes this role through the instance metadata service and receives
# short-lived credentials that AWS rotates automatically.
#
# Long-lived keys are the single most common way a side project leaks: they get
# committed, pasted into a gist, or left on a machine that is later sold. A
# role cannot be copied off the instance in the same way.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project_name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "app" {
  # Write and read raw payloads. Scoped to this bucket's objects only -- not
  # s3:* and not "Resource": "*", which is what most tutorials hand out.
  statement {
    sid    = "RawBucketObjects"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]

    resources = ["${aws_s3_bucket.raw.arn}/*"]
  }

  # Listing is a bucket-level action, so it needs the bucket ARN rather than
  # the object ARN -- a common source of confusing AccessDenied errors.
  statement {
    sid       = "RawBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${var.project_name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# Lets the box be administered through Systems Manager Session Manager, so you
# can get a shell without SSH, without a key pair, and without port 22 open at
# all. An AWS-managed policy is appropriate here: it is maintained by AWS and
# hand-writing the SSM permission set is error-prone.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  # EC2 cannot be given a role directly; it takes an instance profile, which is
  # a container for exactly one role. An AWS wart, not a design choice.
  name = "${var.project_name}-app"
  role = aws_iam_role.app.name
}
