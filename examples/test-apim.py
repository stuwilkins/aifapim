# This code is an example of how to use the Azure OpenAI and Anthropic
# Python libraries to call the AIF APIM gateway.
#
# To run:
#   pip install openai anthropic
#   export AIFAPIM_HOST=<gateway-hostname>
#   export AIFAPIM_API_KEY=<your-apim-subscription-key>
#

import os

from anthropic import Anthropic
from openai import AzureOpenAI, OpenAI
import openai
openai.log = "debug"

# Gateway hostname is required; raises KeyError if unset.
endpoint = f"https://{os.environ['AIFAPIM_HOST']}"

# API version for Azure OpenAI.
api_version = "2024-10-21"

# APIM subscription key (required; raises KeyError if unset).
api_key = os.environ["AIFAPIM_API_KEY"]

def render(content: str) -> None:
    print("\n--- message.content (markdown) ---\n")
    try:
        from rich.console import Console
        from rich.markdown import Markdown

        Console().print(Markdown(content))
    except ImportError:
        print(content)


def run_chat_v1(deployment_name: str) -> None:
    print(f"\n========== Querying deployment: {deployment_name} ==========\n")

    client = OpenAI(
        base_url=f"{endpoint}/openai/v1/",
        api_key="placeholder",
        default_headers={"x-api-key": api_key},
    )

    response = client.responses.create(
        model=deployment_name,
        input=[
            {
                "role": "system",
                "content": "You are an AI assistant that helps people find information. "
                           "Do not make up information and say if you dont know",
            },
            {
                "role": "user",
                "content": "What is the National Synchrotron Light Source II?",
            },
        ]
    )

    for item in response.output[0].content:
        if item.type == "output_text":
            print(item.text)


def run_chat(deployment_name: str) -> None:
    print(f"\n========== Querying deployment: {deployment_name} ==========\n")

    client = AzureOpenAI(
        base_url=f"{endpoint}/deployments/{deployment_name}",
        api_key="placeholder",
        default_headers={"x-api-key": api_key},
        api_version=api_version,
    )

    response = client.chat.completions.create(
        model=deployment_name,
        messages=[
            {
                "role": "system",
                "content": "You are an AI assistant that helps people find information. "
                           "Do not make up information and say if you dont know",
            },
            {
                "role": "user",
                "content": "What is the National Synchrotron Light Source II?",
            },
        ],
        temperature=0.7,
        top_p=0.95,
        max_completion_tokens=800,
    )

    content = response.choices[0].message.content
    if content:
        render(content)


def run_anthropic(deployment_name: str) -> None:
    print(f"\n========== Querying Anthropic deployment: {deployment_name} ==========\n")

    client = Anthropic(
        base_url=f"{endpoint}/anthropic",
        api_key=api_key
    )

    response = client.messages.create(
        model=deployment_name,
        max_tokens=800,
        system=(
            "You are an AI assistant that helps people find information. "
            "Do not make up information and say if you dont know"
        ),
        messages=[
            {
                "role": "user",
                "content": "What is the National Synchrotron Light Source II?",
            },
        ],
    )

    print(response)
    text_blocks = [block.text for block in response.content if getattr(block, "type", None) == "text"]
    content = "\n".join(text_blocks)
    if content:
        render(content)


if __name__ == "__main__":
    # Test the Azure OpenAI GPT model through APIM.
    # Update these deployment names to match your environment's
    # aifapim-<env>.bicepparam modelDeployments entries.
    run_chat("gpt-4.1-mini")

    # Test the Azure OpenAI GPT model through APIM
    run_chat_v1("gpt-4.1-mini")

    # Test the Anthropic Claude model (deployed via Azure AI Foundry) through APIM.
    run_anthropic("claude-sonnet-4-5")

    # Test the Meta Llama model (deployed via Azure AI Foundry) through APIM.
    run_chat("Llama-4-Maverick-17B-128E-Instruct-FP8")
