# Third-Party Notices

Container Compose is released under the MIT License. This file records third-party projects that influence, support, or are linked by the project.

## Apache-2.0 Compliance Status

Container Compose does not vendor, copy, translate, or modify Docker Compose or compose-go source code, tests, assets, or documentation text. Docker Compose and compose-go are used as behavioral compatibility references, and compatibility work should be based on independently written Swift code, observed CLI behavior, and the Compose Specification.

Because the current repository does not redistribute Docker Compose or compose-go source or object code, Docker Compose's Apache-2.0 redistribution conditions are not triggered by the project source itself. If future work imports Apache-2.0 material, that change must preserve the upstream license, copyright notices, NOTICE attribution, and prominent notices for modified copied files before it is merged or released.

## Behavioral References

Container Compose aims to provide Docker Compose-like workflows for Apple's `container` runtime. Docker Compose and compose-go are used as behavioral references for Compose file loading, merge behavior, profile handling, and CLI compatibility.

No Docker Compose or compose-go source code is vendored or copied into this repository. If future changes copy, modify, or vendor Apache-2.0 licensed source from Docker Compose, compose-go, or related projects, the copied files must retain the required notices and the repository must include the relevant Apache-2.0 license and NOTICE attribution.

- Docker Compose: https://github.com/docker/compose
  - License: Apache License 2.0
  - NOTICE: Docker Compose V2 Copyright 2020 Docker Compose authors; includes software developed at Docker, Inc.
- compose-go: https://github.com/compose-spec/compose-go
  - License: Apache License 2.0
- Compose Specification: https://compose-spec.github.io/compose-spec/spec.html

## Swift Package Dependencies

Container Compose currently depends on:

- swift-argument-parser: https://github.com/apple/swift-argument-parser
  - License: Apache License 2.0 with Runtime Library Exception
- Yams: https://github.com/jpsim/Yams
  - License: MIT

Release packaging should include dependency license text when distributing bundled source or binaries in a form that requires third-party license notices.
