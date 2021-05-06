import React from 'react';
import { Link } from 'react-router-dom'

import * as storage from '../../storage'
import Bar from '../bar'
import numberFormatter from '../../number-formatter'
import * as api from '../../api'

export default class PropertyBreakdown extends React.Component {
  constructor(props) {
    super(props)
    let propKey = props.goal.prop_names[0]
    this.storageKey = 'goalPropTab__' + props.site.domain + props.goal.name
    const storedKey = storage.getItem(this.storageKey)
    if (props.goal.prop_names.includes(storedKey)) {
      propKey = storedKey
    }
    if (props.query.filters['props']) {
      propKey = Object.keys(props.query.filters['props'])[0]
    }

    this.state = {
      loading: true,
      propKey: propKey
    }
  }

  componentDidMount() {
    this.fetchPropBreakdown()
  }

  fetchPropBreakdown() {
    if (this.props.query.filters['goal']) {
      api.get(`/api/stats/${encodeURIComponent(this.props.site.domain)}/property/${encodeURIComponent(this.state.propKey)}`, this.props.query)
        .then((res) => this.setState({loading: false, breakdown: res}))
    }
  }

  renderUrl(value) {
    if (value.is_url) {
      return (
        <a target="_blank" href={value.name} className="hidden group-hover:block">
          <svg className="inline h-4 w-4 ml-1 -mt-1 text-gray-600 dark:text-gray-400" fill="currentColor" viewBox="0 0 20 20"><path d="M11 3a1 1 0 100 2h2.586l-6.293 6.293a1 1 0 101.414 1.414L15 6.414V9a1 1 0 102 0V4a1 1 0 00-1-1h-5z"></path><path d="M5 5a2 2 0 00-2 2v8a2 2 0 002 2h8a2 2 0 002-2v-3a1 1 0 10-2 0v3H5V7h3a1 1 0 000-2H5z"></path></svg>
        </a>
      )
    }
    return null
  }
  renderPropValue(value) {
    const query = new URLSearchParams(window.location.search)
    query.set('props', JSON.stringify({[this.state.propKey]: value.name}))

    return (
      <div className="flex items-center justify-between my-2" key={value.name}>
        <div className="w-full h-8 relative" style={{maxWidth: 'calc(100% - 16rem)'}}>
          <Bar count={value.count} all={this.state.breakdown} bg="bg-red-50 dark:bg-gray-500 dark:bg-opacity-15" />
          <span className="flex px-2 group dark:text-gray-300" style={{marginTop: '-26px'}}>
            <Link to={{pathname: window.location.pathname, search: query.toString()}} className="hover:underline block truncate">
              { value.name }
            </Link>
            { this.renderUrl(value) }
          </span>
        </div>
        <div className="dark:text-gray-200">
          <span className="font-medium inline-block w-20 text-right">{numberFormatter(value.count)}</span>
          <span className="font-medium inline-block w-20 text-right">{numberFormatter(value.total_count)}</span>
          <span className="font-medium inline-block w-20 text-right">{numberFormatter(value.conversion_rate)}%</span>
        </div>
      </div>
    )
  }

  changePropKey(newKey) {
    storage.setItem(this.storageKey, newKey)
    this.setState({propKey: newKey, loading: true}, this.fetchPropBreakdown)
  }

  renderBody() {
    if (this.state.loading) {
      return <div className="px-4 py-2"><div className="loading sm mx-auto"><div></div></div></div>
    } else {
      return this.state.breakdown.map((propValue) => this.renderPropValue(propValue))
    }
  }

  renderPill(key) {
    const isActive = this.state.propKey === key

    if (isActive) {
      return <li key={key} className="inline-block h-5 text-indigo-700 dark:text-indigo-500 font-bold border-b-2 border-indigo-700 dark:border-indigo-500 ">{key}</li>
    } else {
      return <li key={key} className="hover:text-indigo-600 cursor-pointer" onClick={this.changePropKey.bind(this, key)}>{key}</li>
    }
  }

  render() {
    return (
      <div className="w-full pl-6 mt-4">
        <div className="flex items-center pb-1">
          <span className="text-xs font-bold text-gray-600 dark:text-gray-300">Breakdown by:</span>
          <ul className="flex font-medium text-xs text-gray-500 dark:text-gray-400 space-x-2 leading-5 pl-1">
            { this.props.goal.prop_names.map(this.renderPill.bind(this)) }
          </ul>
        </div>
        { this.renderBody() }
      </div>
    )
  }
}
