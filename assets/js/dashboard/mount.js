import React from 'react';
import ReactDOM from 'react-dom';
import 'url-search-params-polyfill';

import Router from './router'
import ErrorBoundary from './error-boundary'
import * as api from './api'

const container = document.getElementById('stats-react-container')

if (container) {
  const site = {
    domain: container.dataset.domain,
    offset: container.dataset.offset,
    hasGoals: container.dataset.hasGoals === 'true',
    insertedAt: container.dataset.insertedAt,
    embedded: container.dataset.embedded,
    background: container.dataset.background,
    selfhosted: container.dataset.selfhosted === 'true'
  }

  const loggedIn = container.dataset.loggedIn === 'true'
  const sharedLinkAuth = container.dataset.sharedLinkAuth
  if (sharedLinkAuth) {
    api.setSharedLinkAuth(sharedLinkAuth)
  }

  const app = (
    <ErrorBoundary>
      <Router site={site} loggedIn={loggedIn} />
    </ErrorBoundary>
  )

  ReactDOM.render(app, container);
}
