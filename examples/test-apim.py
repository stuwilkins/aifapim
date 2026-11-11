# This code is an example of how to use the Azure OpenAI and Anthropic
# Python libraries to call the AIF APIM gateway.
#
# To run with pixi (reproducible conda env; manifest in examples/):
#   export AIFAPIM_HOST=<gateway-hostname>
#   export AIFAPIM_API_KEY=<your-apim-subscription-key>
#   cd examples && pixi run example
#   # or, from the repo root:
#   #   pixi run --manifest-path examples/pixi.toml example
#
# Or with a manually-managed Python:
#   pip install openai anthropic
#   export AIFAPIM_HOST=<gateway-hostname>
#   export AIFAPIM_API_KEY=<your-apim-subscription-key>
#   python examples/test-apim.py
#

import base64
import os
import tempfile

import httpx

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

# API version for the image models (Black Forest Labs FLUX). They are served
# under the "preview" version, not the dated chat version above.
image_api_version = "preview"

# FLUX.1-Kontext-pro edits go through the deployments route, which only accepts
# this version (the v1 edit route answers 400 for FLUX).
image_edit_api_version = "2025-04-01-preview"

# Generated images are written here (a new temporary directory per run).
image_dir = tempfile.mkdtemp(prefix="aifapim-images-")

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


def run_embedding_v1(deployment_name: str) -> None:
    print(f"\n========== Embedding deployment: {deployment_name} ==========\n")

    client = OpenAI(
        base_url=f"{endpoint}/openai/v1/",
        api_key="placeholder",
        default_headers={"x-api-key": api_key},
    )

    response = client.embeddings.create(
        model=deployment_name,
        input="The National Synchrotron Light Source II produces some of the "
              "brightest X-rays in the known universe.",
    )

    vector = response.data[0].embedding
    print(f"model={response.model}  dimensions={len(vector)}  "
          f"prompt_tokens={response.usage.prompt_tokens}")


def save_images(response, name: str) -> bytes:
    """Write every image in an images response to image_dir; return the first."""
    first = b""
    for i, item in enumerate(response.data):
        data = base64.b64decode(item.b64_json)
        path = os.path.join(image_dir, f"{name}-{i}.png")
        with open(path, "wb") as f:
            f.write(data)
        print(f"image {i}: {len(data)} bytes -> {path}")
        first = first or data
    return first


def run_image(deployment_name: str) -> bytes:
    """Create an image on the root (deployment) path. Returns the image bytes."""
    print(f"\n========== Image deployment: {deployment_name} ==========\n")

    client = AzureOpenAI(
        base_url=f"{endpoint}/deployments/{deployment_name}",
        api_key="placeholder",
        default_headers={"x-api-key": api_key},
        api_version=image_api_version,
    )

    response = client.images.generate(
        model=deployment_name,
        prompt="A photograph of a red fox in an autumn forest",
        n=1,
        size="1024x1024",
    )
    return save_images(response, f"{deployment_name}-generate")


def run_image_v1(deployment_name: str, edit_source: bytes = b"", edit_via_deployments: bool = False) -> bytes:
    """Create an image on the v1 path; edit edit_source too when it is given.

    edit_via_deployments sends the edit to /deployments/<name>/images/edits
    (FLUX.1-Kontext-pro), because the v1 edit route does not serve FLUX.
    """
    print(f"\n========== Image deployment (v1): {deployment_name} ==========\n")

    client = OpenAI(
        base_url=f"{endpoint}/openai/v1/",
        api_key="placeholder",
        default_headers={"x-api-key": api_key},
        default_query={"api-version": image_api_version},
    )

    response = client.images.generate(
        model=deployment_name,
        prompt="A photograph of a red fox in an autumn forest",
        n=1,
        size="1024x1024",
    )
    created = save_images(response, f"{deployment_name}-v1-generate")

    if edit_source:
        print(f"\n---------- Image edit: {deployment_name} ----------\n")
        if edit_via_deployments:
            edit = httpx.post(
                f"{endpoint}/deployments/{deployment_name}/images/edits",
                params={"api-version": image_edit_api_version},
                headers={"x-api-key": api_key},
                files={"image": ("input.png", edit_source, "image/png")},
                data={"prompt": "Make it a snowy winter scene"},
                timeout=120,
            )
            edit.raise_for_status()
            first = base64.b64decode(edit.json()["data"][0]["b64_json"])
            path = os.path.join(image_dir, f"{deployment_name}-edit-0.png")
            with open(path, "wb") as f:
                f.write(first)
            print(f"image 0: {len(first)} bytes -> {path}")
        else:
            response = client.images.edit(
                model=deployment_name,
                image=("input.png", edit_source, "image/png"),
                prompt="Make it a snowy winter scene",
            )
            save_images(response, f"{deployment_name}-v1-edit")
    return created


def run_flux2(deployment_name: str) -> bytes:
    """Create and edit an image with FLUX.2-pro on the Black Forest Labs provider route.

    Azure serves FLUX.2-pro only at /providers/blackforestlabs/v1/flux-2-pro, with
    JSON parameters; an edit sends the created image as base64 `input_image`.
    """
    print(f"\n========== Image deployment (provider route): {deployment_name} ==========\n")
    url = f"{endpoint}/providers/blackforestlabs/v1/flux-2-pro"
    headers = {"x-api-key": api_key}
    base = {"model": deployment_name, "width": 1024, "height": 1024, "output_format": "png"}

    response = httpx.post(url, headers=headers, timeout=120,
                          json={**base, "prompt": "A photograph of a red fox in an autumn forest"})
    response.raise_for_status()
    created = base64.b64decode(response.json()["data"][0]["b64_json"])
    path = os.path.join(image_dir, f"{deployment_name}-generate-0.png")
    with open(path, "wb") as f:
        f.write(created)
    print(f"image 0: {len(created)} bytes -> {path}")

    print(f"\n---------- Image edit (provider route): {deployment_name} ----------\n")
    response = httpx.post(url, headers=headers, timeout=120,
                          json={**base, "prompt": "Make it a snowy winter scene",
                                "input_image": base64.b64encode(created).decode()})
    response.raise_for_status()
    edited = base64.b64decode(response.json()["data"][0]["b64_json"])
    path = os.path.join(image_dir, f"{deployment_name}-edit-0.png")
    with open(path, "wb") as f:
        f.write(edited)
    print(f"image 0: {len(edited)} bytes -> {path}")
    return created


if __name__ == "__main__":
    # Test the Azure OpenAI GPT model through APIM.
    # Update these deployment names to match your environment's
    # aifapim-<env>.bicepparam modelDeployments entries.
    run_chat("gpt-4.1-mini")

    # Test the Azure OpenAI GPT model through APIM
    run_chat_v1("gpt-4.1-mini")

    # Test the Anthropic Claude model (deployed via Azure AI Foundry) through APIM.
    run_anthropic("claude-sonnet-5-5")

    # Test the Meta Llama model (deployed via Azure AI Foundry) through APIM.
    run_chat("Llama-4-Maverick-17B-128E-Instruct-FP8")

    # Test the Azure OpenAI embedding models through APIM (v1 path).
    # Expects vector lengths: text-embedding-3-large=3072, others=1536.
    run_embedding_v1("text-embedding-3-large")
    run_embedding_v1("text-embedding-3-small")
    run_embedding_v1("text-embedding-ada-002")

    # Test the image models (Black Forest Labs FLUX, DataZoneStandard) through
    # APIM. Each family has its own route:
    #   FLUX.2-pro          create and edit on the provider route only
    #   FLUX.1-Kontext-pro  create on the root and v1 paths; edit through
    #                       /deployments/<name>/images/edits
    #   FLUX-1.1-pro        create only, on the root and v1 paths
    run_flux2("FLUX.2-pro")

    created = run_image("FLUX.1-Kontext-pro")
    run_image_v1("FLUX.1-Kontext-pro", created, edit_via_deployments=True)

    created = run_image("FLUX-1.1-pro")
    run_image_v1("FLUX-1.1-pro")
