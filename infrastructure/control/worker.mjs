import { ControlService } from "./service.mjs";
export class SafetyAuthority {
  constructor(state, env) {
    this.state = state;
    this.service = new ControlService(state.storage, env.JOURNAL, {
      reader: env.READER_SECRET,
      writer: env.WRITER_SECRET,
      admin: env.ADMIN_SECRET,
    });
  }
  fetch(request) {
    return this.state.blockConcurrencyWhile(() => this.service.handle(request));
  }
}
export default {
  fetch(request, env) {
    return env.AUTHORITY.get(env.AUTHORITY.idFromName("signalword-dev")).fetch(
      request,
    );
  },
};
